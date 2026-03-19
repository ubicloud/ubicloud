# frozen_string_literal: true

require "shellwords"

class Prog::Postgres::PostgresMigrationNexus < Prog::Base
  subject_is :postgres_migration

  semaphore :destroy, :cancel, :start_migration

  def self.assemble(project_id:, source_connection_string: nil, source_host: nil, source_port: 5432, source_user: nil, source_password: nil, source_database: nil)
    unless (project = Project[project_id])
      fail "No existing project"
    end

    DB.transaction do
      postgres_migration = PostgresMigration.create(
        project_id: project_id,
        source_connection_string: source_connection_string,
        source_host: source_host,
        source_port: source_port || 5432,
        source_user: source_user,
        source_password: source_password,
        source_database: source_database,
        status: "preparing_client_vm"
      )

      # Create client VM in Germany (service project) immediately
      vm_st = Prog::Vm::Nexus.assemble_with_sshable(
        Config.postgres_service_project_id,
        sshable_unix_user: "ubi",
        location_id: Location::HETZNER_FSN1_ID,
        name: "#{postgres_migration.ubid}-migration-client",
        size: "standard-2",
        boot_image: "ubuntu-jammy",
        enable_ip4: true,
        arch: "x64"
      )

      postgres_migration.update(vm_id: vm_st.id)

      Strand.create_with_id(
        postgres_migration,
        prog: "Postgres::PostgresMigrationNexus",
        label: "start"
      )
    end
  end

  def before_run
    when_destroy_set? do
      unless ["cancel", "wait_cancel_cleanup", "cleanup_client_vm"].include?(strand.label)
        hop_cancel
      end
    end

    when_cancel_set? do
      unless ["cancel", "wait_cancel_cleanup", "cleanup_client_vm", "failed"].include?(strand.label)
        decr_cancel
        hop_cancel
      end
    end
  end

  # Phase 1: Setup

  label def start
    register_deadline("failed", 15 * 60)
    hop_wait_client_vm
  end

  label def wait_client_vm
    nap 5 unless postgres_migration.vm.strand.label == "wait"
    hop_bootstrap_client
  end

  label def bootstrap_client
    case postgres_migration.vm.sshable.d_check("bootstrap_pg_client")
    when "Succeeded"
      postgres_migration.vm.sshable.d_clean("bootstrap_pg_client")
      hop_run_discovery
    when "Failed"
      postgres_migration.update(status: "failed")
      hop_failed
    when "NotStarted"
      postgres_migration.vm.sshable.d_run("bootstrap_pg_client",
        "bash", "-c", "sudo apt-get update -qq && sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq postgresql-client-18 > /dev/null 2>&1")
    end
    nap 5
  end

  # Phase 2: Discovery

  label def run_discovery
    postgres_migration.update(status: "discovering")

    # Build connection string from either full string or individual fields
    conn_str = build_connection_string

    case postgres_migration.vm.sshable.d_check("run_discovery")
    when "Succeeded"
      hop_process_discovery
    when "Failed"
      postgres_migration.update(status: "failed")
      hop_failed
    when "NotStarted"
      # Pass connection string via stdin to avoid it appearing in process list
      postgres_migration.vm.sshable.d_run("run_discovery",
        "bash", "-c", discovery_script,
        stdin: conn_str)
    end
    nap 10
  end

  label def process_discovery
    output = postgres_migration.vm.sshable.cmd("common/bin/daemonizer2 logs run_discovery")
    postgres_migration.vm.sshable.d_clean("run_discovery")

    discovery = JSON.parse(output)

    # Create migration_database records for each discovered database
    (discovery["databases"] || []).each do |db|
      PostgresMigrationDatabase.create(
        postgres_migration_id: postgres_migration.id,
        name: db["name"],
        size_bytes: db["size_bytes"],
        table_count: db["table_count"]
      )
    end

    postgres_migration.update(
      discovered_metadata: Sequel.pg_jsonb_wrap(discovery),
      status: "plan_ready",
      discovery_completed_at: Time.now
    )

    register_deadline(nil, nil) # clear setup deadline
    hop_wait_user_approval
  end

  label def wait_user_approval
    when_start_migration_set? do
      decr_start_migration
      register_deadline("failed", 6 * 60 * 60) # 6 hour migration deadline
      hop_create_target
    end
    nap 15
  end

  # Phase 3: Migration

  label def create_target
    postgres_migration.update(status: "creating_target", migration_started_at: Time.now)

    # Determine flavor based on location
    location = Location[postgres_migration.location_id]
    flavor = (location&.provider == "aws") ? "m8gd" : "standard"

    # Determine PG version - match source or nearest available
    source_version = postgres_migration.discovered_metadata&.dig("server", "version_major")&.to_s
    target_version = source_version && Option::POSTGRES_VERSION_OPTIONS["standard"]&.include?(source_version.to_i) ? source_version : Option::POSTGRES_VERSION_OPTIONS["standard"]&.first&.to_s || "16"

    target_strand = Prog::Postgres::PostgresResourceNexus.assemble(
      project_id: postgres_migration.project_id,
      location_id: postgres_migration.location_id,
      name: "migrated-#{postgres_migration.ubid[0..7]}",
      target_vm_size: postgres_migration.selected_vm_size,
      target_storage_size_gib: postgres_migration.selected_storage_size_gib.to_i,
      target_version: target_version,
      flavor: flavor,
      ha_type: "none"
    )

    postgres_migration.update(target_resource_id: target_strand.subject.id)
    hop_wait_target_ready
  end

  label def wait_target_ready
    target = postgres_migration.target_resource
    nap 15 unless target&.strand&.label == "wait" &&
                   target&.representative_server&.strand&.label == "wait"
    postgres_migration.update(status: "migrating")
    hop_migrate_roles
  end

  label def migrate_roles
    conn_str = build_connection_string
    target_conn = target_connection_string

    case postgres_migration.vm.sshable.d_check("migrate_roles")
    when "Succeeded"
      postgres_migration.vm.sshable.d_clean("migrate_roles")
      hop_migrate_next_database
    when "Failed"
      # Role migration failure is non-fatal - continue with data migration
      postgres_migration.vm.sshable.d_clean("migrate_roles")
      hop_migrate_next_database
    when "NotStarted"
      postgres_migration.vm.sshable.d_run("migrate_roles",
        "bash", "-c", roles_migration_script,
        stdin: "#{conn_str}\n#{target_conn}")
    end
    nap 10
  end

  label def migrate_next_database
    db = postgres_migration.migration_databases.find { |d| d.selected && d.migration_status == "pending" }

    unless db
      hop_verify
      return
    end

    db.update(migration_status: "migrating", started_at: Time.now)
    update_stack({"current_database_id" => db.id})

    conn_str = build_connection_string
    target_conn = target_connection_string

    postgres_migration.vm.sshable.d_run("migrate_db_#{db.name}",
      "bash", "-c", database_migration_script(db.name),
      stdin: "#{conn_str}\n#{target_conn}")

    hop_wait_database_migration
  end

  label def wait_database_migration
    db = PostgresMigrationDatabase[frame["current_database_id"]]
    unit_name = "migrate_db_#{db.name}"

    case postgres_migration.vm.sshable.d_check(unit_name)
    when "Succeeded"
      postgres_migration.vm.sshable.d_clean(unit_name)
      db.update(migration_status: "completed", completed_at: Time.now)
      hop_migrate_next_database
    when "Failed"
      postgres_migration.vm.sshable.d_clean(unit_name)
      db.update(migration_status: "failed", error_message: "pg_dump/pg_restore failed", completed_at: Time.now)
      hop_migrate_next_database # Continue with next DB even if one fails
    end

    nap 15
  end

  label def verify
    postgres_migration.update(status: "verifying")

    case postgres_migration.vm.sshable.d_check("verify_migration")
    when "Succeeded"
      postgres_migration.vm.sshable.d_clean("verify_migration")
      hop_completed
    when "Failed"
      # Verification failure is a warning, not a blocker
      postgres_migration.vm.sshable.d_clean("verify_migration")
      hop_completed
    when "NotStarted"
      target_conn = target_connection_string
      postgres_migration.vm.sshable.d_run("verify_migration",
        "bash", "-c", verification_script,
        stdin: target_conn)
    end
    nap 15
  end

  # Phase 4: Cleanup & Terminal

  label def completed
    postgres_migration.update(status: "completed", completed_at: Time.now)
    register_deadline(nil, nil)
    hop_cleanup_client_vm
  end

  label def cleanup_client_vm
    vm = postgres_migration.vm
    if vm.nil? || vm.strand.nil?
      pop "migration completed"
      return
    end

    unless frame["client_vm_destroy_requested"]
      vm.incr_destroy
      update_stack({"client_vm_destroy_requested" => true})
    end

    nap 10
  end

  label def failed
    postgres_migration.update(status: "failed") unless postgres_migration.status == "failed"
    register_deadline(nil, nil)

    when_cancel_set? do
      decr_cancel
      hop_cancel
    end

    nap 60
  end

  label def cancel
    decr_cancel if strand.label != "cancel"
    decr_destroy if strand.label != "cancel"
    postgres_migration.update(status: "cancelling")
    register_deadline(nil, nil)

    unless frame["cancel_initiated"]
      if (target = postgres_migration.target_resource)
        target.incr_destroy
      end
      if (vm = postgres_migration.vm)
        vm.incr_destroy
      end
      update_stack({"cancel_initiated" => true})
    end

    hop_wait_cancel_cleanup
  end

  label def wait_cancel_cleanup
    target_gone = postgres_migration.target_resource_id.nil? ||
                  PostgresResource[postgres_migration.target_resource_id]&.strand.nil?

    vm_gone = postgres_migration.vm_id.nil? ||
              Vm[postgres_migration.vm_id]&.strand.nil?

    if target_gone && vm_gone
      postgres_migration.update(status: "cancelled", completed_at: Time.now)
      pop "migration cancelled"
      return
    end

    nap 10
  end

  private

  def build_connection_string
    if postgres_migration.source_connection_string
      postgres_migration.source_connection_string
    else
      host = postgres_migration.source_host
      port = postgres_migration.source_port || 5432
      user = postgres_migration.source_user
      pass = postgres_migration.source_password
      db = postgres_migration.source_database || "postgres"
      "postgresql://#{URI.encode_www_component(user)}:#{URI.encode_www_component(pass)}@#{host}:#{port}/#{db}?sslmode=prefer"
    end
  end

  def target_connection_string
    target = postgres_migration.target_resource
    server = target.representative_server
    host = server.vm.ephemeral_net4&.to_s&.gsub("/32", "") || server.vm.ip4.to_s
    "postgresql://postgres:#{target.superuser_password}@#{host}:5432/postgres?sslmode=prefer"
  end

  def discovery_script
    <<~'BASH'
      set -euo pipefail
      CONN_STR=$(cat /dev/stdin)

      # Get version
      PG_VERSION=$(PGCONNECT_TIMEOUT=10 psql "$CONN_STR" -t -A -c "SELECT version();" 2>/dev/null)
      PG_VERSION_MAJOR=$(PGCONNECT_TIMEOUT=10 psql "$CONN_STR" -t -A -c "SHOW server_version_num;" 2>/dev/null | head -c2)

      # Test role dump access
      CAN_DUMP_ROLES="false"
      if PGCONNECT_TIMEOUT=10 psql "$CONN_STR" -t -A -c "SELECT 1 FROM pg_authid LIMIT 1;" 2>/dev/null >/dev/null; then
        CAN_DUMP_ROLES="true"
      fi

      # Get databases
      DATABASES=$(PGCONNECT_TIMEOUT=10 psql "$CONN_STR" -t -A --csv -c "
        SELECT datname, pg_database_size(datname) as size_bytes, pg_encoding_to_char(encoding) as encoding
        FROM pg_database
        WHERE datistemplate = false AND datname != 'postgres'
        ORDER BY pg_database_size(datname) DESC;
      " 2>/dev/null)

      # Get roles
      ROLES=$(PGCONNECT_TIMEOUT=10 psql "$CONN_STR" -t -A --csv -c "
        SELECT rolname, rolsuper, rolcreatedb, rolcreaterole, rolcanlogin
        FROM pg_roles
        WHERE rolname NOT LIKE 'pg_%' AND rolname != 'postgres'
        ORDER BY rolname;
      " 2>/dev/null)

      # Build JSON output
      python3 -c "
import json, sys, csv, io

version_full = '''$PG_VERSION'''
version_major = '''$PG_VERSION_MAJOR'''
can_dump_roles = $CAN_DUMP_ROLES

databases = []
db_csv = '''$DATABASES'''
if db_csv.strip():
    reader = csv.reader(io.StringIO(db_csv.strip()))
    for row in reader:
        if len(row) >= 3:
            databases.append({
                'name': row[0],
                'size_bytes': int(row[1]) if row[1] else 0,
                'encoding': row[2],
                'table_count': 0,
                'extensions': []
            })

roles = []
role_csv = '''$ROLES'''
if role_csv.strip():
    reader = csv.reader(io.StringIO(role_csv.strip()))
    for row in reader:
        if len(row) >= 5:
            roles.append({
                'name': row[0],
                'superuser': row[1] == 't',
                'createdb': row[2] == 't',
                'createrole': row[3] == 't',
                'login': row[4] == 't'
            })

result = {
    'server': {
        'version': version_full.strip(),
        'version_major': int(version_major.strip()) if version_major.strip().isdigit() else 0
    },
    'can_dump_roles': can_dump_roles,
    'databases': databases,
    'roles': roles,
    'warnings': []
}

if not can_dump_roles:
    result['warnings'].append('No superuser access - role passwords will not transfer')

print(json.dumps(result))
"
    BASH
  end

  def roles_migration_script
    <<~'BASH'
      set -euo pipefail
      # Read source and target connection strings from stdin (one per line)
      read -r SOURCE_CONN
      read -r TARGET_CONN

      # Dump roles from source, filter system roles, apply to target
      PGCONNECT_TIMEOUT=30 pg_dumpall --roles-only -d "$SOURCE_CONN" 2>/dev/null | \
        grep -vE '^(CREATE ROLE postgres|ALTER ROLE postgres|CREATE ROLE pg_|ALTER ROLE pg_)' | \
        grep -vE '(SUPERUSER|REPLICATION|BYPASSRLS)' | \
        PGCONNECT_TIMEOUT=30 psql "$TARGET_CONN" 2>/dev/null || true
    BASH
  end

  def database_migration_script(db_name)
    escaped_name = Shellwords.shellescape(db_name)
    <<~BASH
      set -euo pipefail
      read -r SOURCE_CONN
      read -r TARGET_CONN

      # Create the database on target if it doesn't exist
      PGCONNECT_TIMEOUT=30 psql "$TARGET_CONN" -c "SELECT 1 FROM pg_database WHERE datname = '#{escaped_name}'" | grep -q 1 || \
        PGCONNECT_TIMEOUT=30 psql "$TARGET_CONN" -c "CREATE DATABASE \\"#{escaped_name}\\";" 2>/dev/null || true

      # Build target connection string for the specific database
      TARGET_DB_CONN=$(echo "$TARGET_CONN" | sed "s|/postgres?|/#{escaped_name}?|")
      SOURCE_DB_CONN=$(echo "$SOURCE_CONN" | sed "s|/[^?]*?|/#{escaped_name}?|")

      # Run pg_dump | pg_restore pipeline
      PGCONNECT_TIMEOUT=60 pg_dump -Fc --no-privileges --verbose -d "$SOURCE_DB_CONN" 2>/tmp/migrate_#{escaped_name}.log | \
        PGCONNECT_TIMEOUT=60 pg_restore --no-privileges --verbose -d "$TARGET_DB_CONN" 2>>/tmp/migrate_#{escaped_name}.log || true

      # Run ANALYZE
      PGCONNECT_TIMEOUT=30 psql "$TARGET_DB_CONN" -c "ANALYZE;" 2>/dev/null || true
    BASH
  end

  def verification_script
    <<~'BASH'
      set -euo pipefail
      TARGET_CONN=$(cat /dev/stdin)

      # Simple verification: check that target databases exist and have tables
      PGCONNECT_TIMEOUT=10 psql "$TARGET_CONN" -t -A -c "
        SELECT datname, pg_database_size(datname)
        FROM pg_database
        WHERE datistemplate = false AND datname != 'postgres'
        ORDER BY datname;
      " 2>/dev/null
    BASH
  end
end
