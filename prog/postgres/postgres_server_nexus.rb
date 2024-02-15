# frozen_string_literal: true

require "forwardable"

require_relative "../../lib/util"

class Prog::Postgres::PostgresServerNexus < Prog::Base
  subject_is :postgres_server

  extend Forwardable
  def_delegators :postgres_server, :vm

  semaphore :initial_provisioning, :refresh_certificates, :update_superuser_password, :checkup, :configure, :update_firewall_rules, :take_over, :destroy

  def self.assemble(resource_id:, timeline_id:, timeline_access:, representative_at: nil)
    DB.transaction do
      ubid = PostgresServer.generate_ubid

      postgres_resource = PostgresResource[resource_id]
      vm_st = Prog::Vm::Nexus.assemble_with_sshable(
        "ubi",
        Config.postgres_service_project_id,
        location: postgres_resource.location,
        name: ubid.to_s,
        size: postgres_resource.target_vm_size,
        storage_volumes: [
          {encrypted: true, size_gib: 30},
          {encrypted: true, size_gib: postgres_resource.target_storage_size_gib}
        ],
        boot_image: "postgres-ubuntu-2204",
        enable_ip4: true,
        allow_only_ssh: true
      )

      synchronization_status = representative_at ? "ready" : "catching_up"
      postgres_server = PostgresServer.create(
        resource_id: resource_id,
        timeline_id: timeline_id,
        timeline_access: timeline_access,
        representative_at: representative_at,
        synchronization_status: synchronization_status,
        vm_id: vm_st.id
      ) { _1.id = ubid.to_uuid }

      postgres_server.create_resource_firewall_rules

      Strand.create(prog: "Postgres::PostgresServerNexus", label: "start") { _1.id = postgres_server.id }
    end
  end

  def before_run
    when_destroy_set? do
      if strand.label != "destroy"
        hop_destroy
      end
    end
  end

  label def start
    nap 5 unless vm.strand.label == "wait"

    postgres_server.incr_initial_provisioning
    hop_bootstrap_rhizome
  end

  label def bootstrap_rhizome
    register_deadline(:wait, 10 * 60)

    bud Prog::BootstrapRhizome, {"target_folder" => "postgres", "subject_id" => vm.id, "user" => "ubi"}
    hop_wait_bootstrap_rhizome
  end

  label def wait_bootstrap_rhizome
    reap
    hop_mount_data_disk if leaf?
    donate
  end

  label def mount_data_disk
    case vm.sshable.cmd("common/bin/daemonizer --check format_disk")
    when "Succeeded"
      vm.sshable.cmd("sudo mkdir -p /dat")
      device_path = vm.vm_storage_volumes.find { _1.boot == false }.device_path.shellescape

      vm.sshable.cmd("sudo common/bin/add_to_fstab #{device_path} /dat ext4 defaults 0 0")
      vm.sshable.cmd("sudo mount #{device_path} /dat")

      hop_configure_walg_credentials
    when "Failed", "NotStarted"
      device_path = vm.vm_storage_volumes.find { _1.boot == false }.device_path.shellescape
      vm.sshable.cmd("common/bin/daemonizer 'sudo mkfs --type ext4 #{device_path}' format_disk")
    end

    nap 5
  end

  label def configure_walg_credentials
    refresh_walg_credentials
    hop_initialize_empty_database if postgres_server.primary?
    hop_initialize_database_from_backup
  end

  label def initialize_empty_database
    case vm.sshable.cmd("common/bin/daemonizer --check initialize_empty_database")
    when "Succeeded"
      hop_refresh_certificates
    when "Failed", "NotStarted"
      vm.sshable.cmd("common/bin/daemonizer 'sudo postgres/bin/initialize-empty-database' initialize_empty_database")
    end

    nap 5
  end

  label def initialize_database_from_backup
    case vm.sshable.cmd("common/bin/daemonizer --check initialize_database_from_backup")
    when "Succeeded"
      hop_refresh_certificates
    when "Failed", "NotStarted"
      backup_label = if postgres_server.standby?
        "LATEST"
      else
        postgres_server.timeline.latest_backup_label_before_target(target: postgres_server.resource.restore_target)
      end
      vm.sshable.cmd("common/bin/daemonizer 'sudo postgres/bin/initialize-database-from-backup #{backup_label}' initialize_database_from_backup")
    end

    nap 5
  end

  label def refresh_certificates
    decr_refresh_certificates

    nap 5 if postgres_server.resource.server_cert.nil?

    ca_bundle = [postgres_server.resource.root_cert_1, postgres_server.resource.root_cert_2].join("\n")
    vm.sshable.cmd("sudo -u postgres tee /dat/16/data/ca.crt > /dev/null", stdin: ca_bundle)
    vm.sshable.cmd("sudo -u postgres tee /dat/16/data/server.crt > /dev/null", stdin: postgres_server.resource.server_cert)
    vm.sshable.cmd("sudo -u postgres tee /dat/16/data/server.key > /dev/null", stdin: postgres_server.resource.server_cert_key)
    vm.sshable.cmd("sudo -u postgres chmod 600 /dat/16/data/server.key")

    # MinIO cluster certificate rotation timelines are similar to postgres
    # servers' timelines. So we refresh the wal-g credentials which uses MinIO
    # certificates when we refresh the certificates of the postgres server.
    refresh_walg_credentials

    when_initial_provisioning_set? do
      hop_configure
    end

    vm.sshable.cmd("sudo -u postgres pg_ctlcluster 16 main reload")
    hop_wait
  end

  label def configure
    decr_configure

    case vm.sshable.cmd("common/bin/daemonizer --check configure_postgres")
    when "Succeeded"
      vm.sshable.cmd("common/bin/daemonizer --clean configure_postgres")

      when_initial_provisioning_set? do
        hop_update_superuser_password if postgres_server.primary?
        hop_wait_catch_up if postgres_server.standby?
        hop_wait_recovery_completion
      end

      hop_wait_catch_up if postgres_server.standby? && postgres_server.synchronization_status != "ready"
      hop_wait
    when "Failed", "NotStarted"
      configure_hash = postgres_server.configure_hash
      vm.sshable.cmd("common/bin/daemonizer 'sudo postgres/bin/configure' configure_postgres", stdin: JSON.generate(configure_hash))
    end

    nap 5
  end

  label def update_superuser_password
    decr_update_superuser_password

    encrypted_password = DB.synchronize do |conn|
      # This uses PostgreSQL's PQencryptPasswordConn function, but it needs a connection, because
      # the encryption is made by PostgreSQL, not by control plane. We use our own control plane
      # database to do the encryption.
      conn.encrypt_password(postgres_server.resource.superuser_password, "postgres", "scram-sha-256")
    end
    commands = <<SQL
BEGIN;
SET LOCAL log_statement = 'none';
ALTER ROLE postgres WITH PASSWORD #{DB.literal(encrypted_password)};
COMMIT;
SQL
    postgres_server.run_query(commands)

    when_initial_provisioning_set? do
      hop_wait if retval&.dig("msg") == "postgres server is restarted"
      push self.class, frame, "restart"
    end

    hop_wait
  end

  label def wait_catch_up
    query = "SELECT pg_current_wal_lsn() - replay_lsn FROM pg_stat_replication WHERE application_name = '#{postgres_server.ubid}'"
    lag = postgres_server.resource.representative_server.run_query(query).chomp

    nap 30 if lag.empty? || lag.to_i > 80 * 1024 * 1024 # 80 MB or ~5 WAL files

    postgres_server.update(synchronization_status: "ready")
    postgres_server.resource.representative_server.incr_configure
    hop_wait_synchronization if postgres_server.resource.ha_type == PostgresResource::HaType::SYNC
    hop_wait
  end

  label def wait_synchronization
    query = "SELECT sync_state FROM pg_stat_replication WHERE application_name = '#{postgres_server.ubid}'"
    sync_state = postgres_server.resource.representative_server.run_query(query).chomp
    hop_wait if ["quorum", "sync"].include?(sync_state)

    nap 30
  end

  label def wait_recovery_completion
    is_in_recovery = postgres_server.run_query("SELECT pg_is_in_recovery()").chomp == "t"

    if is_in_recovery
      is_wal_replay_paused = postgres_server.run_query("SELECT pg_get_wal_replay_pause_state()").chomp == "paused"
      if is_wal_replay_paused
        postgres_server.run_query("SELECT pg_wal_replay_resume()")
        is_in_recovery = false
      end
    end

    if !is_in_recovery
      timeline_id = Prog::Postgres::PostgresTimelineNexus.assemble(parent_id: postgres_server.timeline.id).id
      postgres_server.timeline_id = timeline_id
      postgres_server.timeline_access = "push"
      postgres_server.save_changes

      refresh_walg_credentials

      hop_configure
    end

    nap 5
  end

  label def wait
    decr_initial_provisioning

    when_take_over_set? do
      hop_wait_primary_destroy
    end

    when_refresh_certificates_set? do
      hop_refresh_certificates
    end

    when_update_superuser_password_set? do
      hop_update_superuser_password
    end

    when_checkup_set? do
      hop_unavailable if !available?
    end

    when_update_firewall_rules_set? do
      decr_update_firewall_rules
      hop_update_firewall_rules
    end

    when_configure_set? do
      hop_configure
    end

    nap 30
  end

  label def update_firewall_rules
    register_deadline(:wait, 1 * 60)

    # destroy the previous set of firewall rules
    vm.firewalls.select { _1.name == postgres_server.ubid.to_s }.each(&:destroy)

    # create a new set of firewall rules
    postgres_server.create_resource_firewall_rules
    vm.incr_update_firewall_rules

    hop_wait
  end

  label def unavailable
    register_deadline(:wait, 10 * 60)

    if postgres_server.primary? && (standby = postgres_server.failover_target)
      standby.incr_take_over
      postgres_server.incr_destroy
      nap 0
    end

    reap
    nap 5 unless strand.children.select { _1.prog == "Postgres::PostgresServerNexus" && _1.label == "restart" }.empty?

    if available?
      decr_checkup
      hop_wait
    end

    bud self.class, frame, :restart
    nap 5
  end

  label def wait_primary_destroy
    decr_take_over
    hop_take_over if postgres_server.resource.representative_server.nil?
    nap 5
  end

  label def take_over
    case vm.sshable.cmd("common/bin/daemonizer --check promote_postgres")
    when "Succeeded"
      postgres_server.update(timeline_access: "push", representative_at: Time.now)
      postgres_server.resource.incr_refresh_dns_record
      postgres_server.resource.servers.each(&:incr_configure)
      postgres_server.resource.servers.reject(&:primary?).each { _1.update(synchronization_status: "catching_up") }
      hop_configure
    when "Failed", "NotStarted"
      vm.sshable.cmd("common/bin/daemonizer 'sudo pg_ctlcluster 16 main promote' promote_postgres")
      nap 0
    end

    nap 5
  end

  label def destroy
    decr_destroy

    strand.children.each { _1.destroy }
    vm.private_subnets.each { _1.incr_destroy }
    vm.incr_destroy
    postgres_server.destroy

    pop "postgres server is deleted"
  end

  label def restart
    vm.sshable.cmd("sudo postgres/bin/restart")
    pop "postgres server is restarted"
  end

  def refresh_walg_credentials
    return if postgres_server.timeline.blob_storage.nil?

    walg_config = postgres_server.timeline.generate_walg_config
    vm.sshable.cmd("sudo -u postgres tee /etc/postgresql/wal-g.env > /dev/null", stdin: walg_config)
    vm.sshable.cmd("sudo tee /usr/lib/ssl/certs/blob_storage_ca.crt > /dev/null", stdin: postgres_server.timeline.blob_storage.root_certs)
  end

  def available?
    vm.sshable.invalidate_cache_entry

    begin
      postgres_server.run_query("SELECT 1")
      return true
    rescue
    end

    # Do not declare unavailability if Postgres is in crash recovery
    begin
      return true if vm.sshable.cmd("sudo tail -n 5 /dat/16/data/pg_log/postgresql.log").include?("redo in progress")
    rescue
    end

    false
  end
end
