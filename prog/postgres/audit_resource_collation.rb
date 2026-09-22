# frozen_string_literal: true

require "csv"

# Audits one Postgres resource's primary for collations that were NOT verified as
# order-stable across the Ubuntu 22.04 (glibc 2.35) -> 26.04 (glibc 2.43) bump.
#
# "Verified order-stable" (UBI-351): the builtin provider, and C / POSIX /
# C.UTF-8 / C.UTF8 (collversion IS NULL, codepoint order). Everything else that
# is version-tracked (collversion IS NOT NULL: ICU, libc en_US, ...) can re-order
# when the C library changes, so an index built under it may be corrupt after the
# move.
#
# The audit is fail-closed, because a missed database can leave a corrupt index
# after the migration. It inspects EVERY database, not just the default one:
# collations, the database default collation, and per-object collation are all
# per-database, so one connection cannot see another database's objects. It lists
# the databases first, then runs AUDIT_SQL inside each connectable one. Anything
# it cannot verify -- a database it cannot query, a server it cannot enumerate --
# is flagged for manual review rather than passed as clean.
class Prog::Postgres::AuditResourceCollation < Prog::Base
  subject_is :postgres_resource

  # Lists every database with its connectability and whether its default
  # collation is version-tracked. datallowconn=false databases (e.g. template0)
  # cannot be connected to for object inspection, but their default collation is
  # still readable here from the shared pg_database catalog.
  DATABASES_SQL = <<~SQL
    SELECT datname, datallowconn,
      CASE WHEN datlocprovider='b' THEN false
           WHEN datlocprovider='i' THEN true
           WHEN datcollate IN ('C','POSIX','C.UTF-8','C.UTF8','ucs_basic') THEN false
           ELSE true END AS default_unsafe,
      datcollate
    FROM pg_database
    ORDER BY datname;
  SQL

  # A single row of scalar columns, so PostgresServer#run_query (psql -t --csv)
  # returns one clean CSV line. Frozen (frozen_string_literal) so run_query
  # accepts it without a Sequel dataset. Run once per connectable database.
  AUDIT_SQL = <<~SQL
    WITH safe(name) AS (SELECT unnest(ARRAY['C','POSIX','C.UTF-8','C.UTF8','ucs_basic']::text[])),
    def AS (
      SELECT datlocprovider::text AS prov, datcollate,
        CASE WHEN datlocprovider='b' THEN false
             WHEN datlocprovider='i' THEN true
             WHEN datcollate IN (SELECT name FROM safe) OR datcollate IN ('C','POSIX') THEN false
             ELSE true END AS unsafe
      FROM pg_database WHERE datname=current_database()
    ),
    risky AS (
      SELECT c.oid, c.collname FROM pg_collation c
      WHERE c.collversion IS NOT NULL AND c.collname NOT IN (SELECT name FROM safe)
    ),
    expl_col AS (
      SELECT r.collname FROM pg_attribute a JOIN risky r ON r.oid=a.attcollation
      JOIN pg_class rel ON rel.oid=a.attrelid JOIN pg_namespace n ON n.oid=rel.relnamespace
      WHERE a.attnum>0 AND NOT a.attisdropped AND rel.relkind IN ('r','m','p')
        AND n.nspname NOT IN ('pg_catalog','information_schema')
    ),
    expl_idx AS (
      SELECT DISTINCT i.indexrelid, r.collname FROM pg_index i JOIN pg_class rel ON rel.oid=i.indexrelid
      JOIN pg_namespace n ON n.oid=rel.relnamespace JOIN LATERAL unnest(i.indcollation) u(coll) ON true
      JOIN risky r ON r.oid=u.coll WHERE n.nspname NOT IN ('pg_catalog','information_schema')
    ),
    expl_dom AS (
      SELECT r.collname FROM pg_type t JOIN risky r ON r.oid=t.typcollation
      JOIN pg_namespace n ON n.oid=t.typnamespace
      WHERE t.typtype='d' AND n.nspname NOT IN ('pg_catalog','information_schema')
    ),
    inh_col AS (
      SELECT count(*) n FROM pg_attribute a JOIN pg_class rel ON rel.oid=a.attrelid JOIN pg_namespace n ON n.oid=rel.relnamespace
      WHERE (SELECT unsafe FROM def) AND a.attnum>0 AND NOT a.attisdropped AND a.attcollation=100
        AND rel.relkind IN ('r','m','p') AND n.nspname NOT IN ('pg_catalog','information_schema')
    ),
    inh_idx AS (
      SELECT count(DISTINCT i.indexrelid) n FROM pg_index i JOIN pg_class rel ON rel.oid=i.indexrelid
      JOIN pg_namespace n ON n.oid=rel.relnamespace JOIN LATERAL unnest(i.indcollation) u(coll) ON true
      WHERE (SELECT unsafe FROM def) AND u.coll=100 AND n.nspname NOT IN ('pg_catalog','information_schema')
    ),
    used AS (
      SELECT collname FROM expl_col
      UNION SELECT collname FROM expl_idx
      UNION SELECT collname FROM expl_dom
      UNION SELECT datcollate FROM def WHERE (SELECT unsafe FROM def)
    )
    SELECT
      (SELECT unsafe FROM def)        AS default_flagged,
      (SELECT datcollate FROM def)    AS default_collation,
      (SELECT prov FROM def)          AS default_provider,
      (SELECT count(*) FROM expl_col) AS explicit_columns,
      (SELECT count(*) FROM expl_idx) AS explicit_indexes,
      (SELECT count(*) FROM expl_dom) AS explicit_domains,
      (SELECT n FROM inh_col)         AS inherited_columns,
      (SELECT n FROM inh_idx)         AS inherited_indexes,
      (SELECT string_agg(DISTINCT collname, '|' ORDER BY collname) FROM used) AS flagged_collations;
  SQL

  def self.assemble(postgres_resource_id)
    Strand.create(prog: "Postgres::AuditResourceCollation", label: "start", stack: [{"subject_id" => postgres_resource_id}])
  end

  def before_run
    pop "postgres resource is gone" if postgres_resource.nil? || postgres_resource.destroying_set?
  end

  label def start
    register_deadline(nil, 15 * 60, page: false)
    hop_audit
  end

  label def audit
    server = postgres_resource.representative_server
    pop({"msg" => "skipped", "reason" => "no representative server"}) if server.nil? || server.vm.nil?

    databases =
      begin
        parse_databases(server.run_query(DATABASES_SQL))
      rescue Sshable::SshError => e
        error = e.stderr.lines.first.to_s.strip
        emit_unreachable(error)
        pop({"msg" => "unreachable", "error" => error})
      end

    if databases.empty?
      emit_unreachable("no databases returned")
      pop({"msg" => "unreachable", "error" => "no databases returned"})
    end

    audited = databases.map { audit_database(server, it) }
    flagged_databases = audited.select { database_flagged?(it) }.map { it[:name] }
    unverified_databases = audited.select { it[:connectable] && !it[:queried] }.map { it[:name] }
    flagged = !flagged_databases.empty? || !unverified_databases.empty?

    result = {databases: audited, flagged_databases:, unverified_databases:, flagged:}
    Clog.emit("postgres collation audit", {postgres_collation_audit: result.merge(resource: postgres_resource.ubid, project: postgres_resource.project.ubid)})

    pop(flagged ? {"msg" => "flagged", "flagged_databases" => flagged_databases, "unverified_databases" => unverified_databases} : {"msg" => "clean"})
  end

  # Inspects one database. A connectable database is queried with AUDIT_SQL; a
  # query failure marks it unverified (queried:false) so the caller flags it. A
  # non-connectable database cannot be inspected for objects, but its default
  # collation is already known from DATABASES_SQL.
  def audit_database(server, database)
    return {name: database[:name], connectable: false, queried: false, default_flagged: database[:default_unsafe], default_collation: database[:default_collation]} unless database[:connectable]

    begin
      parse_result(server.run_query(AUDIT_SQL, dbname: database[:name])).merge(name: database[:name], connectable: true, queried: true)
    rescue Sshable::SshError
      {name: database[:name], connectable: true, queried: false}
    end
  end

  # A database is flagged when its default collation is version-tracked or it
  # holds any explicitly non-verified column, index, or domain. Inherited counts
  # are informational: they only matter when the default is already flagged.
  def database_flagged?(database)
    database[:default_flagged] || database[:explicit_columns].to_i > 0 ||
      database[:explicit_indexes].to_i > 0 || database[:explicit_domains].to_i > 0
  end

  # Maps the DATABASES_SQL rows to typed values, one hash per database.
  def parse_databases(output)
    (CSV.parse(output) || []).map do |row|
      {name: row[0], connectable: row[1] == "t", default_unsafe: row[2] == "t", default_collation: row[3]}
    end
  end

  # Maps the single CSV row from AUDIT_SQL to typed values. When nothing is
  # flagged, string_agg returns NULL, so the flagged-collations field is empty:
  # cols[8] is "" (or nil when the row carries no trailing field).
  def parse_result(output)
    cols = CSV.parse_line(output) || []
    {
      default_flagged: cols[0] == "t",
      default_collation: cols[1],
      default_provider: cols[2],
      explicit_columns: cols[3].to_i,
      explicit_indexes: cols[4].to_i,
      explicit_domains: cols[5].to_i,
      inherited_columns: cols[6].to_i,
      inherited_indexes: cols[7].to_i,
      flagged_collations: cols[8].to_s.empty? ? [] : cols[8].split("|"),
    }
  end

  def emit_unreachable(error)
    Clog.emit("postgres collation audit unreachable", {postgres_collation_audit: {resource: postgres_resource.ubid, error:}})
  end
end
