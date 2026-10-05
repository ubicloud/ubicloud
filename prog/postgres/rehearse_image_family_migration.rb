# frozen_string_literal: true

require "csv"

# Rehearses an image family migration of a Postgres resource on a private
# fork. It forks the resource into an internal project, audits the fork, moves
# it to the target family, then runs amcheck on the indexes at risk in every
# database. It ends in wait_review with the results in the frame and the Clog
# line, and leaves the fork for an operator to review and destroy.
class Prog::Postgres::RehearseImageFamilyMigration < Prog::Base
  subject_is :postgres_resource

  frame_reader :project_id, :target_image_family
  frame_accessor :fork_id, :databases, :step, :results, :verdict_before, :verdict_after, :status

  AUDIT = Prog::Postgres::AuditResourceCollation

  # The indexes the collation audit lists in the current database: sort-order
  # index rows from DETAILS_SQL and index-backed case-mapping rows from
  # CTYPE_SQL. Reusing the audit's queries keeps the two from drifting.
  TARGETS_SQL = <<~SQL.freeze
    WITH listed(name) AS (
      SELECT name FROM (#{AUDIT::DETAILS_SQL.chomp.delete_suffix(";")}) d WHERE kind = 'index'
      UNION
      SELECT object FROM (#{AUDIT::CTYPE_SQL.chomp.delete_suffix(";")}) c WHERE kind IN ('expression', 'citext', 'pg_trgm')
    )
    SELECT c.oid, c.oid::regclass::text AS name, am.amname
    FROM listed l JOIN pg_class c ON c.oid = l.name::regclass JOIN pg_am am ON am.oid = c.relam
  SQL

  # Every part below records its outcome as rows in
  # ubi_collation_rehearsal.result, a table that exists only on the fork.
  # SETUP_SQL creates it, and a temporary table of the indexes the audit
  # lists.
  SETUP_SQL = <<~SQL.freeze
    CREATE SCHEMA IF NOT EXISTS ubi_collation_rehearsal;
    CREATE TABLE IF NOT EXISTS ubi_collation_rehearsal.result (phase text NOT NULL, object text NOT NULL, ok boolean, detail text,
      started_at timestamptz NOT NULL DEFAULT clock_timestamp(), finished_at timestamptz);
    CREATE TEMP TABLE target AS #{TARGETS_SQL.chomp};
  SQL

  # Runs bt_index_check with heapallindexed, which computes every key again
  # with the current library, on each listed btree index; checkunique also
  # checks uniqueness on PG 17+. amcheck checks btree only, so other access
  # methods are recorded as not checked.
  AMCHECK_SQL = <<~SQL
    CREATE EXTENSION IF NOT EXISTS amcheck;
    ALTER EXTENSION amcheck UPDATE;
    DO $do$
    DECLARE
      t record;
      started timestamptz;
    BEGIN
      FOR t IN SELECT * FROM target WHERE amname = 'btree' ORDER BY oid LOOP
        started := clock_timestamp();
        BEGIN
          IF current_setting('server_version_num')::int >= 170000 THEN
            PERFORM bt_index_check(t.oid::regclass, true, true);
          ELSE
            PERFORM bt_index_check(t.oid::regclass, true);
          END IF;
          INSERT INTO ubi_collation_rehearsal.result VALUES ('amcheck', t.name, true, NULL, started, clock_timestamp());
        EXCEPTION WHEN OTHERS THEN
          INSERT INTO ubi_collation_rehearsal.result VALUES ('amcheck', t.name, false, SQLERRM, started, clock_timestamp());
        END;
      END LOOP;
      INSERT INTO ubi_collation_rehearsal.result
        SELECT 'amcheck', name, NULL, amname || ' index: amcheck checks btree only', clock_timestamp(), clock_timestamp()
        FROM target WHERE amname <> 'btree';
    END
    $do$;
  SQL

  # The psql script run in each database, through the daemonizer because
  # amcheck can outlast a strand lease. A setup error stops it, as nothing
  # after it can work; amcheck records its own failures.
  SCRIPT = <<~SQL.freeze
    \\set ON_ERROR_STOP on
    #{SETUP_SQL}
    #{AMCHECK_SQL}
  SQL

  DATABASES_SQL = "SELECT datname FROM pg_database WHERE datallowconn AND NOT datistemplate ORDER BY datname"

  RESULTS_SQL = <<~SQL
    SELECT phase, object, ok, detail, round(extract(epoch FROM finished_at - started_at)::numeric, 1)
    FROM ubi_collation_rehearsal.result ORDER BY phase, ok NULLS FIRST, object
  SQL

  # Caps the failures kept per phase and database, so the frame stays small.
  FAILURE_LIMIT = 50

  def self.assemble(postgres_resource_id, project_id:, target_image_family: "ubuntu-2604")
    fail "No existing project" unless Project[project_id]
    fail "Unknown image family" unless Option::POSTGRES_IMAGE_FAMILIES.include?(target_image_family)

    Strand.create(prog: "Postgres::RehearseImageFamilyMigration", label: "start",
      stack: [{"subject_id" => postgres_resource_id, "project_id" => project_id, "target_image_family" => target_image_family}])
  end

  label def start
    register_deadline("wait_review", 2 * 24 * 60 * 60, page: false)
    hop_create_fork
  end

  label def create_fork
    if (reason = unsuitable_reason)
      finish(reason)
    end

    begin
      self.fork_id = Prog::Postgres::PostgresResourceNexus.assemble(
        project_id:,
        location_id: postgres_resource.location_id,
        name: fork_name,
        target_vm_size: postgres_resource.target_vm_size,
        target_storage_size_gib: postgres_resource.target_storage_size_gib,
        target_version: postgres_resource.version,
        flavor: postgres_resource.flavor,
        parent_id: postgres_resource.id,
        restore_target: (Time.now - 5 * 60).utc.iso8601,
        user_config: postgres_resource.user_config,
        pgbouncer_user_config: postgres_resource.pgbouncer_user_config,
        with_firewall_rules: false,
      ).id
    rescue Validation::ValidationFailed => e
      finish("fork failed: #{e.message}")
    end

    hop_wait_fork
  end

  label def wait_fork
    finish("fork is gone") unless fork
    nap 30 unless fork.display_state == "running"
    hop_audit_before
  end

  label def audit_before
    bud Prog::Postgres::AuditResourceCollation, {"subject_id" => fork_id}
    hop_wait_audit_before
  end

  label def wait_audit_before
    reap(:migrate, nap: 120, reaper: ->(child) { self.verdict_before = child.exitval })
  end

  label def migrate
    finish("fork is gone") unless fork
    fork.update(target_image_family:)
    hop_wait_migrated
  end

  label def wait_migrated
    finish("fork is gone") unless fork
    nap 60 if fork.needs_convergence? || fork.representative_server.image_family != target_image_family || fork.display_state != "running"
    hop_audit_after
  end

  label def audit_after
    bud Prog::Postgres::AuditResourceCollation, {"subject_id" => fork_id}
    hop_wait_audit_after
  end

  label def wait_audit_after
    reap(:list_databases, nap: 120, reaper: ->(child) { self.verdict_after = child.exitval })
  end

  label def list_databases
    self.databases = CSV.parse(fork.representative_server.run_query(DATABASES_SQL)).map(&:first)
    self.step = 0
    self.results = {}
    hop_wait_database_script
  end

  # Runs SCRIPT in one database at a time and records its results.
  label def wait_database_script
    hop_report if step == databases.size

    sshable = fork.representative_server.vm.sshable
    unit = "collation_rehearsal_#{step}"
    case (state = sshable.d_check(unit))
    when "NotStarted"
      sshable.d_run(unit, "sudo", "-u", "postgres", "psql", "-U", "postgres", "-X", "-d", PostgresServer.conninfo(databases[step]), stdin: SCRIPT)
    when "Succeeded", "Failed"
      log = sshable.d_logs(unit, lines: 20) if state == "Failed"
      self.results = results.merge(databases[step] => database_result(databases[step], state, log))
      sshable.d_clean(unit)
      self.step = step + 1
    end

    nap 5
  end

  label def report
    passed = audit_passed? && results.each_value.all? do |database|
      database["script"] == "Succeeded" && database["phases"].each_value.all? { it["failed"].zero? }
    end
    finish(passed ? "passed" : "review needed")
  end

  # Holds the strand so an operator can review the frame and the fork. To
  # clean up: fork.incr_destroy, then destroy this strand.
  label def wait_review
    hibernate
  end

  def fork
    @fork ||= PostgresResource[fork_id] if fork_id
  end

  def fork_name
    "collation-fork-#{postgres_resource.ubid}"
  end

  def unsuitable_reason
    if postgres_resource.nil?
      "postgres resource is gone"
    elsif postgres_resource.location.project_id
      "location belongs to a project, so the fork would run in that account"
    elsif postgres_resource.display_state != "running"
      "postgres resource is not running"
    elsif postgres_resource.representative_server.image_family == target_image_family
      "postgres resource already runs #{target_image_family}"
    elsif !PostgresResource.where(project_id:, location_id: postgres_resource.location_id, name: fork_name).empty?
      "fork #{fork_name} already exists"
    end
  end

  def database_result(database, state, log)
    result = {"script" => state}
    result["log"] = log.lines.map(&:chomp) if log
    rows = CSV.parse(fork.representative_server.run_query(RESULTS_SQL, dbname: PostgresServer.conninfo(database)))
    result.merge("phases" => rows.group_by(&:first).transform_values { phase_summary(it) })
  rescue Sshable::SshError => e
    result.merge("phases" => {}, "results_error" => e.stderr.lines.first.to_s.strip)
  end

  def phase_summary(rows)
    failed = rows.select { it[2] == "f" }
    {"ok" => rows.count { it[2] == "t" }, "failed" => failed.size, "unchecked" => rows.count { it[2].nil? },
     "seconds" => rows.sum { it[4].to_f }.round(1),
     "failures" => failed.first(FAILURE_LIMIT).map { |_, object, _, detail| {"object" => object, "detail" => detail} }}
  end

  # The audit must have run on both sides of the migration and agree, and the
  # fork must not need a blocker or a manual review.
  def audit_passed?
    return false unless verdict_before && verdict_after
    !%w[skipped unreachable].include?(verdict_after["msg"]) && !(verdict_after["actions"] || []).intersect?(%w[blocker review]) &&
      verdict_before.slice("msg", "actions") == verdict_after.slice("msg", "actions")
  end

  def finish(status)
    self.status = status
    summary = {resource: postgres_resource&.ubid, fork: fork&.ubid, status:, verdict_before:, verdict_after:, results:}
    Clog.emit("postgres image family rehearsal", {postgres_image_family_rehearsal: summary})
    hop_wait_review
  end
end
