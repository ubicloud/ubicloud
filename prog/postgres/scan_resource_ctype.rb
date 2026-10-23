# frozen_string_literal: true

require "csv"
require "json"

# Scans the data behind the glibc case-mapping objects of a Postgres resource
# before it moves from Ubuntu 22.04 (glibc 2.35) to 26.04 (glibc 2.43). That
# change adds case mappings and changes character classes, all outside ASCII.
# The collation audit lists these objects with the action "scan". A table
# whose columns behind them hold only ASCII keeps the same values on the
# target, so its objects need nothing; any other table needs them rebuilt
# after the move. It is fail-closed: an object it cannot resolve to columns,
# or a scan that fails, is reported for review.
class Prog::Postgres::ScanResourceCtype < Prog::Base
  subject_is :postgres_resource

  AUDIT = Prog::Postgres::AuditResourceCollation

  DATABASES_SQL = "SELECT datname FROM pg_database WHERE datallowconn AND datname <> 'template0' ORDER BY datname"

  # The audit's case-mapping objects whose rules come from glibc. Reusing its
  # query keeps the two from drifting.
  AUDIT_OBJECTS_SQL = <<~SQL
    SELECT kind, object FROM (#{AUDIT::CTYPE_SQL.chomp.delete_suffix(";")}) c WHERE source = 'glibc'
  SQL

  # The parts below list the columns each object reads, as (kind, object,
  # relid, attnum), each for one kind of audit row.
  #
  # An index reads its plain key columns (indkey) and the columns in its
  # expressions and predicate (pg_depend). A primary key or unique constraint
  # index has no pg_depend rows, so both are needed.
  INDEX_COLUMNS = <<~SQL
    SELECT a.kind, a.object, i.indrelid, k FROM audit a
    JOIN pg_index i ON i.indexrelid = to_regclass(a.object)
    CROSS JOIN LATERAL unnest(i.indkey::int2[]) k
    WHERE a.kind IN ('expression', 'citext', 'pg_trgm') AND k > 0
    UNION
    SELECT a.kind, a.object, d.refobjid, d.refobjsubid FROM audit a
    JOIN pg_depend d ON d.classid = 'pg_class'::regclass AND d.objid = to_regclass(a.object)
      AND d.refclassid = 'pg_class'::regclass AND d.refobjsubid > 0
    WHERE a.kind IN ('expression', 'citext', 'pg_trgm')
  SQL

  # A stored generated column reads the columns in its expression. Postgres
  # also records the expression as depending on the column itself.
  GENERATED_COLUMNS = <<~SQL
    SELECT a.kind, a.object, d.refobjid, d.refobjsubid FROM audit a
    JOIN pg_attribute att ON att.attgenerated = 's' AND format('%s.%I', att.attrelid::regclass, att.attname) = a.object
    JOIN pg_attrdef ad ON ad.adrelid = att.attrelid AND ad.adnum = att.attnum
    JOIN pg_depend d ON d.classid = 'pg_attrdef'::regclass AND d.objid = ad.oid
      AND d.refclassid = 'pg_class'::regclass AND d.refobjsubid > 0
    WHERE a.kind = 'stored_column'
  SQL

  # A plain tsvector column is filled by a trigger or the application, so its
  # source is unknown: every text-like column of its table, itself included.
  # Its own lexemes are not enough, as a character that became a letter was
  # dropped from them as a separator.
  TSVECTOR_COLUMNS = <<~SQL
    SELECT a.kind, a.object, att.attrelid, col.attnum FROM audit a
    JOIN pg_attribute att ON att.attgenerated = '' AND att.atttypid = 'tsvector'::regtype
      AND format('%s.%I', att.attrelid::regclass, att.attname) = a.object
    JOIN pg_attribute col ON col.attrelid = att.attrelid AND col.attnum > 0 AND NOT col.attisdropped
    JOIN pg_type t ON t.oid = col.atttypid
    WHERE a.kind = 'stored_column' AND t.typcategory IN ('S', 'A', 'U')
  SQL

  # A table check constraint reads the columns in conkey. A domain check
  # constraint reads every table column of the domain type.
  CHECK_COLUMNS = <<~SQL
    SELECT a.kind, a.object, con.conrelid, k FROM audit a
    JOIN pg_constraint con ON con.contype = 'c' AND con.conrelid <> 0
      AND format('%s.%I', con.conrelid::regclass, con.conname) = a.object
    CROSS JOIN LATERAL unnest(con.conkey) k
    WHERE a.kind = 'check_constraint'
    UNION
    SELECT a.kind, a.object, att.attrelid, att.attnum FROM audit a
    JOIN pg_constraint con ON con.contype = 'c' AND con.contypid <> 0
      AND format('%s.%I', con.contypid::regtype, con.conname) = a.object
    JOIN pg_attribute att ON att.atttypid = con.contypid AND att.attnum > 0 AND NOT att.attisdropped
    JOIN pg_class r ON r.oid = att.attrelid AND r.relkind IN ('r', 'p') AND NOT r.relispartition
    WHERE a.kind = 'check_constraint'
  SQL

  # Postgres records each column a partition key reads, plain or in an
  # expression, as an internal dependency of that column on its own table.
  PARTITION_KEY_COLUMNS = <<~SQL
    SELECT a.kind, a.object, d.objid, d.objsubid FROM audit a
    JOIN pg_depend d ON d.classid = 'pg_class'::regclass AND d.objid = to_regclass(a.object) AND d.objsubid > 0
      AND d.refclassid = 'pg_class'::regclass AND d.refobjid = d.objid AND d.refobjsubid = 0 AND d.deptype = 'i'
    WHERE a.kind = 'partition_key'
  SQL

  # One row per table: its objects, and a query that counts its rows with a
  # character outside ASCII (0x01-0x7F) in any column they read, and its size
  # with its partitions (pg_partition_tree has no rows for a table that is not
  # partitioned). The regex compares code points only, so glibc cannot change
  # its answer. The query prints a marker, so its counts can be found in the
  # journal. A materialized view gets "refresh", and an object with no columns
  # found gets "unresolved", so it is not passed as safe.
  TARGETS_SQL = <<~SQL.freeze
    WITH audit AS (#{AUDIT_OBJECTS_SQL.chomp}),
    cols(kind, object, relid, attnum) AS (
      #{[INDEX_COLUMNS, GENERATED_COLUMNS, TSVECTOR_COLUMNS, CHECK_COLUMNS, PARTITION_KEY_COLUMNS].join("UNION\n").chomp}
    )
    SELECT 'scan' AS action, c.relid::regclass::text AS relation,
      jsonb_agg(DISTINCT jsonb_build_object('kind', c.kind, 'object', c.object))::text AS objects,
      coalesce((SELECT sum(pg_table_size(relid))::bigint FROM pg_partition_tree(c.relid)), pg_table_size(c.relid)) AS size_bytes,
      format('SELECT %L AS marker, count(*) FILTER (WHERE %s) AS nonascii, count(*) AS total FROM %s', 'ctype_scan_counts',
        string_agg(DISTINCT format('%I::text ~ ''[^\\x01-\\x7f]''', att.attname), ' OR '), c.relid::regclass) AS query
    FROM cols c JOIN pg_attribute att ON att.attrelid = c.relid AND att.attnum = c.attnum
    GROUP BY c.relid
    UNION ALL
    SELECT CASE WHEN kind = 'materialized_view' THEN 'refresh' ELSE 'unresolved' END, object,
      jsonb_build_array(jsonb_build_object('kind', kind, 'object', object))::text, NULL, NULL
    FROM audit a
    WHERE kind = 'materialized_view' OR NOT EXISTS (SELECT 1 FROM cols c WHERE c.kind = a.kind AND c.object = a.object)
    ORDER BY 1, 2;
  SQL

  # The journal line with a scan's counts, after the journal's own prefix.
  COUNTS_LINE = /ctype_scan_counts,(\d+),(\d+)$/

  # journald can receive a unit's output after the unit has exited, so a log
  # without the counts is read again this many times before the scan counts
  # as failed.
  LOG_READ_LIMIT = 12

  EMPTY_RESULT = {"safe" => 0, "rebuild" => [], "large" => [], "failed" => [], "refresh" => [], "unresolved" => []}.freeze

  frame_reader :max_table_gib
  frame_accessor :databases, :targets, :step, :results, :log_reads

  # A table larger than max_table_gib is not scanned, but listed as "large"
  # for a scan on a fork. nil scans every table, as on a fork.
  def self.assemble(postgres_resource_id, max_table_gib: 10)
    Strand.create(prog: "Postgres::ScanResourceCtype", label: "start",
      stack: [{"subject_id" => postgres_resource_id, "max_table_gib" => max_table_gib}])
  end

  def before_run
    pop "postgres resource is gone" if postgres_resource.nil? || postgres_resource.destroying_set?
  end

  label def start
    register_deadline(nil, 24 * 60 * 60, page: false)
    hop_list_databases
  end

  label def list_databases
    databases = CSV.parse(server.run_query(DATABASES_SQL)).map(&:first)
    pop({"msg" => "unreachable", "error" => "no databases returned"}) if databases.empty?
    self.databases = databases
    self.results = {}
    self.step = 0
    hop_list_targets
  rescue Sshable::SshError => e
    pop({"msg" => "unreachable", "error" => e.stderr.lines.first.to_s.strip})
  end

  # Lists the tables to scan in the next database, and records the objects
  # that need no scan and the tables too large to scan here.
  label def list_targets
    database = databases[results.size]
    rows = CSV.parse(server.run_query(TARGETS_SQL, dbname: PostgresServer.conninfo(database))).map do |action, relation, objects, size_bytes, query|
      {"action" => action, "relation" => relation, "objects" => JSON.parse(objects).map { "#{it["kind"]}: #{it["object"]}" }, "size_bytes" => size_bytes&.to_i, "query" => query}
    end
    scans, others = rows.partition { it["query"] }
    large, scans = scans.partition { max_table_gib && it["size_bytes"] > max_table_gib * 2**30 }
    outcome = others.group_by { it["action"] }.transform_values { it.flat_map { it["objects"] } }
    start_database(database, scans, outcome.merge("large" => large.map { it.slice("relation", "objects", "size_bytes") }))
  rescue Sshable::SshError => e
    start_database(database, [], {"failed" => [{"error" => e.stderr.lines.first.to_s.strip}]})
  end

  # Scans one table at a time through the daemonizer, as a scan can outlast a
  # strand lease. The query goes in as an argument and the counts come back
  # through the journal, so nothing is written to a file on the server. On a
  # failure, the log tail keeps the psql error with its DETAIL and CONTEXT
  # lines after the systemd lines.
  label def wait_table_scan
    if targets.empty?
      hop_report if results.size == databases.size
      hop_list_targets
    end

    target = targets.first
    case server.vm.sshable.d_check(unit)
    when "NotStarted"
      server.vm.sshable.d_run(unit, "sudo", "-u", "postgres", "psql", "-U", "postgres", "-X", "-d", PostgresServer.conninfo(database),
        "-t", "--csv", "-v", "ON_ERROR_STOP=1", "-c", target["query"])
    when "Succeeded"
      log = server.vm.sshable.d_logs(unit, lines: 20)
      if (counts = log.scan(COUNTS_LINE).last)
        nonascii, total = counts.map(&:to_i)
        record(nonascii.zero? ? {"safe" => 1} : {"rebuild" => [target.slice("relation", "objects", "size_bytes").merge("nonascii" => nonascii, "total" => total)]})
      elsif (self.log_reads = log_reads.to_i + 1) >= LOG_READ_LIMIT
        record("failed" => [target.slice("relation", "objects").merge("error" => ["no counts in the log"] + log.lines.map(&:chomp))])
      end
    when "Failed"
      error = server.vm.sshable.d_logs(unit, lines: 20).lines.map(&:chomp)
      record("failed" => [target.slice("relation", "objects").merge("error" => error)])
    end

    nap 5
  end

  label def report
    rebuild, large, failed, refresh, unresolved = %w[rebuild large failed refresh unresolved].map do |key|
      results.select { |_, result| result[key].any? }.keys
    end
    msg = if failed.any? || unresolved.any?
      "review"
    elsif large.any?
      "fork_scan"
    elsif rebuild.any?
      "rebuild"
    else
      "clean"
    end

    result = {"msg" => msg, "rebuild_databases" => rebuild, "large_databases" => large, "failed_databases" => failed,
              "refresh_databases" => refresh, "unresolved_databases" => unresolved, "databases" => results}
    Clog.emit("postgres ctype scan", {postgres_ctype_scan: result.merge("resource" => postgres_resource.ubid)})
    pop result
  end

  # A caught-up standby is read when there is one, so the full-table scans
  # stay off the primary. A standby that is still catching up refuses
  # connections.
  def server
    @server ||= begin
      server = postgres_resource.representative_server
      pop({"msg" => "skipped", "reason" => "no representative server"}) unless server&.vm
      (server.primary? && postgres_resource.servers_dataset.exclude(vm_id: nil).first(timeline_access: "fetch", synchronization_status: "ready")) || server
    end
  end

  def database
    databases[results.size - 1]
  end

  def start_database(database, targets, outcome)
    self.results = results.merge(database => EMPTY_RESULT.merge(outcome))
    self.targets = targets
    hop_wait_table_scan
  end

  def unit
    "ctype_scan_#{strand.ubid}_#{step}"
  end

  # Merges a table's outcome into its database result, then cleans up its
  # unit and moves to the next table. The frame is saved only when the label
  # returns, so if the clean fails, the next run reads the same unit again.
  def record(outcome)
    self.results = results.merge(database => results[database].merge(outcome) { |_, old, new| old + new })
    server.vm.sshable.d_clean(unit)
    self.targets = targets.drop(1)
    self.step = step + 1
    self.log_reads = 0
  end
end
