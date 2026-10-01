# frozen_string_literal: true

require "csv"

# Audits a Postgres resource before it moves from Ubuntu 22.04 (glibc 2.35) to
# 26.04 (glibc 2.43). It checks every database for sort order on collations
# that are not verified order-stable (UBI-351), and for objects that store
# case-mapped values. It is fail-closed: anything it cannot check is reported
# for review, not passed as clean. Each verdict lists the actions it needs, most
# severe first (ACTIONS).
class Prog::Postgres::AuditResourceCollation < Prog::Base
  subject_is :postgres_resource

  # Lists every database. Its default is safe only when it is builtin, or libc
  # with locale C, POSIX, or C.* (case-insensitive, as Postgres compares them).
  # Anything else is unsafe, so a missing version field or a new provider
  # cannot pass as safe. The shared pg_database catalog also gives the default of
  # a database that does not allow connections. The ICU locale column was
  # renamed in PG 17, hence the jsonb lookup.
  DATABASES_SQL = <<~SQL
    SELECT datname, datallowconn,
      NOT coalesce(datlocprovider='b' OR (datlocprovider='c' AND (lower(datcollate) IN ('c','posix') OR datcollate ILIKE 'c.%')), false) AS default_unsafe,
      datcollate,
      CASE WHEN datlocprovider='i' THEN true
           WHEN datlocprovider='c' AND datctype NOT IN ('C','POSIX') THEN true
           ELSE false END AS ctype_at_risk,
      datlocprovider, datctype,
      coalesce(to_jsonb(d)->>'datlocale', to_jsonb(d)->>'daticulocale') AS icu_locale
    FROM pg_database d
    ORDER BY datname;
  SQL

  # Lists a database's non-verified collations in use, then the indexes,
  # columns, and domains on them, largest index first. Index rows on the
  # default carry collation "default"; the default's own entry comes from
  # DATABASES_SQL. Partitions are left out, so a partitioned object counts once.
  DETAILS_SQL = <<~SQL
    WITH coll AS (
      SELECT oid, collname::text AS collname, collprovider::text AS provider, collcollate AS locale FROM pg_collation WHERE oid<>100
      UNION ALL
      SELECT 100, 'default', datlocprovider::text, datcollate FROM pg_database WHERE datname=current_database()
    ),
    risky AS (
      SELECT oid, collname FROM coll
      WHERE NOT coalesce(provider='b' OR (provider='c' AND (lower(locale) IN ('c','posix') OR locale ILIKE 'c.%')), false)
    ),
    idx AS (
      SELECT DISTINCT i.indexrelid, u.coll FROM pg_index i JOIN pg_class rel ON rel.oid=i.indexrelid
      JOIN pg_namespace n ON n.oid=rel.relnamespace JOIN LATERAL unnest(i.indcollation) u(coll) ON true
      WHERE NOT rel.relispartition AND n.nspname NOT IN ('pg_catalog','information_schema')
        AND u.coll IN (SELECT oid FROM risky)
    ),
    col AS (
      SELECT a.attrelid, a.attname, a.attcollation AS coll FROM pg_attribute a
      JOIN pg_class rel ON rel.oid=a.attrelid JOIN pg_namespace n ON n.oid=rel.relnamespace
      WHERE a.attnum>0 AND NOT a.attisdropped AND rel.relkind IN ('r','m','p') AND NOT rel.relispartition
        AND n.nspname NOT IN ('pg_catalog','information_schema') AND a.attcollation IN (SELECT oid FROM risky WHERE oid<>100)
    ),
    dom AS (
      SELECT t.oid, t.typcollation AS coll FROM pg_type t JOIN pg_namespace n ON n.oid=t.typnamespace
      WHERE t.typtype='d' AND n.nspname NOT IN ('pg_catalog','information_schema') AND t.typcollation IN (SELECT oid FROM risky WHERE oid<>100)
    ),
    used AS (SELECT coll FROM idx UNION SELECT coll FROM col UNION SELECT coll FROM dom)
    SELECT * FROM (
      SELECT 'collation', c.collname::text, c.collname::text, c.collprovider::text,
        CASE WHEN c.collprovider='i' THEN coalesce(to_jsonb(c)->>'colllocale', to_jsonb(c)->>'colliculocale') ELSE c.collcollate END,
        c.collctype, c.collisdeterministic, NULL::bool, NULL::bigint
      FROM pg_collation c WHERE c.oid IN (SELECT coll FROM used) AND c.oid<>100
      UNION ALL
      SELECT 'index', i.indexrelid::regclass::text, r.collname,
        NULL, NULL, NULL, NULL, x.indisunique, pg_relation_size(i.indexrelid)
      FROM idx i JOIN pg_index x ON x.indexrelid=i.indexrelid JOIN risky r ON r.oid=i.coll
      UNION ALL
      SELECT 'column', format('%s.%I', col.attrelid::regclass, col.attname), r.collname, NULL, NULL, NULL, NULL, NULL, NULL
      FROM col JOIN risky r ON r.oid=col.coll
      UNION ALL
      SELECT 'domain', dom.oid::regtype::text, r.collname, NULL, NULL, NULL, NULL, NULL, NULL
      FROM dom JOIN risky r ON r.oid=dom.coll
    ) d(kind, name, collname, provider, locale, ctype, deterministic, is_unique, size_bytes)
    ORDER BY array_position(ARRAY['collation','index','column','domain'], kind), size_bytes DESC NULLS LAST, name;
  SQL

  # Lists objects that store or index case-mapped values, with the source of
  # their case rules: "glibc" needs a data scan, "icu" a REINDEX. The source
  # comes from each object's key or column collation; default (oid 100),
  # to_tsvector, pg_trgm, and tsvector use the database ctype. A COLLATE inside
  # a generated expression is not seen, which errs toward reporting. Objects on
  # builtin or C/POSIX (ASCII) rules are left out.
  #
  # Single-quoted heredoc so the regex escapes reach Postgres. citext is matched
  # by typname, as the extension may be absent or outside search_path.
  CTYPE_SQL = <<~'SQL'
    WITH dflt AS (
      SELECT CASE WHEN datlocprovider = 'i' THEN 'icu'
                  WHEN datlocprovider = 'c' AND datctype NOT IN ('C', 'POSIX') THEN 'glibc' END AS source
      FROM pg_database WHERE datname = current_database()
    ),
    idx AS (
      SELECT i.indexrelid, i.indrelid, i.indkey, i.indclass, pg_get_indexdef(i.indexrelid) AS def,
        array_remove(i.indcollation::oid[], 0::oid) AS colls
      FROM pg_index i JOIN pg_class c ON c.oid = i.indexrelid
      WHERE NOT c.relispartition
        AND c.relnamespace NOT IN ('pg_catalog'::regnamespace, 'information_schema'::regnamespace, 'pg_toast'::regnamespace)
    ),
    objs AS (
      SELECT 'expression' AS kind, indexrelid::regclass::text AS object,
        CASE WHEN def ~* '\mto_tsvector\s*\(' OR colls = '{}' THEN colls || 100::oid ELSE colls END AS colls
      FROM idx WHERE def ~* '\m(lower|upper|initcap|to_tsvector)\s*\('
      UNION ALL
      SELECT 'citext', indexrelid::regclass::text, CASE WHEN colls = '{}' THEN ARRAY[100::oid] ELSE colls END
      FROM idx WHERE EXISTS (
        SELECT 1 FROM pg_attribute a JOIN pg_type t ON t.oid = a.atttypid LEFT JOIN pg_type bt ON bt.oid = t.typbasetype
        WHERE a.attrelid = idx.indrelid AND a.attnum = ANY(idx.indkey::int2[]) AND 'citext' IN (t.typname, bt.typname))
      UNION ALL
      SELECT 'pg_trgm', indexrelid::regclass::text, ARRAY[100::oid]
      FROM idx WHERE EXISTS (
        SELECT 1 FROM pg_opclass oc WHERE oc.oid = ANY(idx.indclass::oid[]) AND oc.opcname IN ('gin_trgm_ops', 'gist_trgm_ops'))
      UNION ALL
      SELECT 'stored_column', format('%s.%I', a.attrelid::regclass, a.attname),
        CASE WHEN a.atttypid = 'tsvector'::regtype OR a.attcollation = 0 THEN ARRAY[100::oid] ELSE ARRAY[a.attcollation] END
      FROM pg_attribute a JOIN pg_class c ON c.oid = a.attrelid
      LEFT JOIN pg_attrdef d ON d.adrelid = a.attrelid AND d.adnum = a.attnum
      WHERE c.relkind IN ('r', 'p') AND NOT c.relispartition AND a.attnum > 0 AND NOT a.attisdropped
        AND c.relnamespace NOT IN ('pg_catalog'::regnamespace, 'information_schema'::regnamespace, 'pg_toast'::regnamespace)
        AND (a.atttypid = 'tsvector'::regtype
             OR (a.attgenerated = 's' AND pg_get_expr(d.adbin, d.adrelid) ~* '\m(lower|upper|initcap)\s*\('))
    ),
    sourced AS (
      SELECT o.kind, o.object,
        CASE WHEN u.coll = 100 THEN (SELECT source FROM dflt)
             WHEN pc.collprovider = 'i' THEN 'icu'
             WHEN pc.collprovider = 'c' AND pc.collctype NOT IN ('C', 'POSIX') THEN 'glibc' END AS source
      FROM objs o CROSS JOIN LATERAL unnest(o.colls) u(coll) LEFT JOIN pg_collation pc ON pc.oid = u.coll
    )
    SELECT kind, object, CASE WHEN bool_or(source = 'icu') THEN 'icu' ELSE 'glibc' END AS source
    FROM sourced GROUP BY kind, object HAVING bool_or(source IS NOT NULL)
    ORDER BY kind, object;
  SQL

  # Caps the object names kept per database, so the frame and log stay small.
  OBJECT_LIMIT = 50

  # Caps the databases named in a verdict, which lands in the strand's exitval.
  # The verdict still gives the totals, and the Clog line keeps every database.
  DATABASE_LIMIT = 20

  # libc locales in the ubuntu-2604 image, asserted by its build
  # (postgres-vm-images common/setup_base.sh). UBI-351 proved each of them
  # order-identical from glibc 2.35 to 2.43, so a libc collation on them needs
  # only REFRESH COLLATION VERSION. Any other libc locale cannot load on the
  # target, which blocks the move. A locale added to the image needs the same
  # proof before it joins this list.
  TARGET_LIBC_LOCALES = %w[C POSIX C.utf8 en_US.utf8].freeze

  # The actions a verdict can ask for, most severe first.
  ACTIONS = %w[blocker review reindex scan refresh].freeze

  frame_accessor :databases, :results

  def self.assemble(postgres_resource_id)
    Strand.create(prog: "Postgres::AuditResourceCollation", label: "start", stack: [{"subject_id" => postgres_resource_id}])
  end

  def before_run
    pop "postgres resource is gone" if postgres_resource.nil? || postgres_resource.destroying_set?
  end

  label def start
    register_deadline(nil, 15 * 60, page: false)
    hop_enumerate
  end

  # Each label run does at most one query, so a label stays well inside the
  # strand lease however many databases the resource has.
  label def enumerate
    databases =
      begin
        parse_databases(server.run_query(DATABASES_SQL))
      rescue Sshable::SshError => e
        pop_unreachable(e.stderr.lines.first.to_s.strip)
      end
    pop_unreachable("no databases returned") if databases.empty?

    # Two queries per database, each with a 60s statement timeout.
    register_deadline(nil, (5 + 2 * databases.size) * 60, allow_extension: true, page: false)
    self.databases = databases
    self.results = []
    hop_audit_details
  end

  label def audit_details
    self.results = results + [database_details(databases[results.size])]
    hop_audit_ctype
  end

  label def audit_ctype
    *done, current = results
    self.results = done + [current.merge(database_ctype(databases[done.size]))]
    hop_report if results.size == databases.size
    hop_audit_details
  end

  label def report
    flagged_databases = results.select { it["flagged"] }.map { it["name"] }
    unverified_databases = results.reject { it["details_verified"] && it["ctype_verified"] }.map { it["name"] }
    ctype_databases = results.reject { it["ctype_object_count"].zero? }.to_h do
      [it["name"], {"objects" => it["ctype_objects"], "total" => it["ctype_object_count"], "sources" => it["ctype_sources"]}]
    end
    details = results.select { it["details"] }.to_h { [it["name"], it["details"]] }
    actions = resource_actions(results, unverified_databases)
    flagged = !flagged_databases.empty? || !unverified_databases.empty?

    result = {databases: results, flagged_databases:, unverified_databases:, ctype_databases:, details:, actions:, flagged:}
    Clog.emit("postgres collation audit", {postgres_collation_audit: result.merge(resource: postgres_resource.ubid, project: UBID.from_uuidish(postgres_resource.project_id).to_s)})

    totals = {"flagged" => flagged_databases.size, "unverified" => unverified_databases.size, "ctype" => ctype_databases.size}
    if flagged
      pop({"msg" => "flagged", "flagged_databases" => flagged_databases.first(DATABASE_LIMIT), "unverified_databases" => unverified_databases.first(DATABASE_LIMIT),
           "ctype_databases" => ctype_databases.first(DATABASE_LIMIT).to_h, "details" => details.first(DATABASE_LIMIT).to_h, "database_totals" => totals, "actions" => actions})
    elsif !ctype_databases.empty?
      pop({"msg" => "ctype_review", "ctype_databases" => ctype_databases.first(DATABASE_LIMIT).to_h, "database_totals" => totals, "actions" => actions})
    else
      pop({"msg" => "clean"})
    end
  end

  def server
    @server ||= begin
      server = postgres_resource.representative_server
      pop({"msg" => "skipped", "reason" => "no representative server"}) unless server&.vm
      server
    end
  end

  # Describes one database's non-verified collations, each with the action it
  # needs, and the objects on them. The database is flagged when it has any: an
  # unsafe default (known from DATABASES_SQL) or a DETAILS_SQL row. Objects on a
  # "refresh" collation are left out: their order is unchanged, so there is
  # nothing to rebuild. A non-connectable database can only report its default,
  # and a failed query keeps the default but marks the database unverified.
  def database_details(database)
    collations = database["default_unsafe"] ? [default_collation(database)] : []
    return database_result(database, collations, []) unless database["connectable"]

    begin
      rows = CSV.parse(server.run_query(DETAILS_SQL, dbname: conninfo(database["name"])))
    rescue Sshable::SshError
      return database_result(database, collations, [], verified: false)
    end

    collation_rows, object_rows = rows.partition { it[0] == "collation" }
    collations += collation_rows.map do |_, name, _, provider, locale, ctype, deterministic|
      {"collation" => name, "provider" => provider, "locale" => locale, "ctype" => ctype, "deterministic" => deterministic == "t", "action" => collation_action(provider, [locale, ctype])}
    end
    action_for = collations.to_h { [it["collation"], it["action"]] }
    objects = object_rows.filter_map do |kind, name, collation, *, unique, size|
      next if action_for[collation] == "refresh"
      object = {"kind" => kind, "object" => name, "collation" => collation, "action" => action_for[collation]}
      (kind == "index") ? object.merge("unique" => unique == "t", "size_bytes" => size.to_i) : object
    end
    database_result(database, collations, objects)
  end

  def database_result(database, collations, objects, verified: true)
    result = {"name" => database["name"], "connectable" => database["connectable"], "flagged" => !collations.empty?, "details_verified" => verified}
    result["details"] = {"collations" => collations, "objects" => objects.first(OBJECT_LIMIT), "object_total" => objects.length} unless collations.empty?
    result
  end

  # Lists one database's case-mapping objects. It runs in every connectable
  # database, as an explicit ICU or libc collation can put an object at risk
  # where the database ctype is not. A failed query is unverified, and so is a
  # database it cannot connect to whose own ctype is at risk. template0 is
  # skipped, as it cannot hold user objects and its ctype is often C.UTF8, which
  # would flag nearly every cluster.
  def database_ctype(database)
    none = {"ctype_verified" => true, "ctype_objects" => [], "ctype_object_count" => 0, "ctype_sources" => {}}
    return none if database["name"] == "template0"
    return none.merge("ctype_verified" => !database["ctype_at_risk"]) unless database["connectable"]

    objects = CSV.parse(server.run_query(CTYPE_SQL, dbname: conninfo(database["name"]))).map { |kind, object, source| {"kind" => kind, "object" => object, "source" => source} }
    {"ctype_verified" => true, "ctype_objects" => objects.first(OBJECT_LIMIT), "ctype_object_count" => objects.length, "ctype_sources" => objects.map { it["source"] }.tally}
  rescue Sshable::SshError
    none.merge("ctype_verified" => false)
  end

  # The database default as a collation entry. Postgres does not allow a
  # nondeterministic default.
  def default_collation(database)
    locale = (database["provider"] == "i") ? database["icu_locale"] : database["default_collation"]
    {"collation" => "default", "provider" => database["provider"], "locale" => locale, "ctype" => database["ctype"], "deterministic" => true,
     "action" => collation_action(database["provider"], [database["default_collation"], database["ctype"]])}
  end

  # ICU brings its own sort and case tables, which move with the ICU version, so
  # an index on it needs a REINDEX. A libc collation is safe to refresh only if
  # every locale it names is on the target image.
  def collation_action(provider, locales)
    return "reindex" if provider == "i"
    (locales.compact.map { normalize_locale(it) } - TARGET_LIBC_LOCALES).empty? ? "refresh" : "blocker"
  end

  # Brings a glibc locale name to the form `locale -a` prints: the codeset is
  # lowercased without dashes, so en_US.UTF-8 and en_US.utf8 compare equal.
  def normalize_locale(name)
    base, codeset = name.split(".", 2)
    codeset ? "#{base}.#{codeset.downcase.delete("-")}" : base
  end

  def resource_actions(results, unverified_databases)
    actions = results.flat_map { |db| db.dig("details", "collations")&.map { it["action"] } || [] }
    actions += results.flat_map { it["ctype_sources"].keys }.map { (it == "icu") ? "reindex" : "scan" }
    actions << "review" unless unverified_databases.empty?
    ACTIONS & actions
  end

  # Maps the DATABASES_SQL rows to typed values, one hash per database. The
  # keys are strings, as the list is kept in the frame.
  def parse_databases(output)
    CSV.parse(output).map do |row|
      {"name" => row[0], "connectable" => row[1] == "t", "default_unsafe" => row[2] == "t", "default_collation" => row[3], "ctype_at_risk" => row[4] == "t",
       "provider" => row[5], "ctype" => row[6], "icu_locale" => row[7]}
    end
  end

  # psql reads a -d value that contains "=" or starts with a URI prefix as a
  # connection string. Database names are customer-controlled, so each one goes
  # in as a quoted conninfo value.
  def conninfo(dbname)
    "dbname='#{dbname.gsub(/[\\']/) { "\\#{it}" }}'"
  end

  def pop_unreachable(error)
    Clog.emit("postgres collation audit unreachable", {postgres_collation_audit: {resource: postgres_resource.ubid, error:}})
    pop({"msg" => "unreachable", "error" => error})
  end
end
