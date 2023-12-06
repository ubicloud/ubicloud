# frozen_string_literal: true

require "forwardable"

require_relative "../../lib/util"

class Prog::Postgres::PostgresServerNexus < Prog::Base
  subject_is :postgres_server

  extend Forwardable
  def_delegators :postgres_server, :vm

  semaphore :initial_provisioning, :refresh_certificates, :update_superuser_password, :destroy

  def self.assemble(resource_id:, timeline_id:, timeline_access:)
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
        boot_image: "ubuntu-jammy",
        enable_ip4: true
      )

      vm_st.subject.private_subnets.each { _1.firewall_rules.each(&:destroy) }
      vm_st.subject.add_allow_ssh_fw_rules(vm_st.subject.private_subnets.first)
      ["0.0.0.0/0", "::/0"].each do |ip|
        FirewallRule.create_with_id(
          ip: ip,
          private_subnet_id: vm_st.subject.private_subnets.first.id,
          port_range: Sequel.pg_range(5432..5432)
        )
      end

      postgres_server = PostgresServer.create(
        resource_id: resource_id,
        timeline_id: timeline_id,
        timeline_access: timeline_access,
        vm_id: vm_st.id
      ) { _1.id = ubid.to_uuid }

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

      hop_install_postgres
    when "Failed", "NotStarted"
      device_path = vm.vm_storage_volumes.find { _1.boot == false }.device_path.shellescape
      vm.sshable.cmd("common/bin/daemonizer 'sudo mkfs --type ext4 #{device_path}' format_disk")
    end

    nap 5
  end

  label def install_postgres
    case vm.sshable.cmd("common/bin/daemonizer --check install_postgres")
    when "Succeeded"
      hop_install_walg
    when "Failed", "NotStarted"
      vm.sshable.cmd("common/bin/daemonizer 'sudo postgres/bin/install_postgres' install_postgres")
    end

    nap 5
  end

  label def install_walg
    case vm.sshable.cmd("common/bin/daemonizer --check install_wal-g")
    when "Succeeded"
      refresh_walg_credentials

      hop_initialize_empty_database if postgres_server.primary?
      hop_initialize_database_from_backup
    when "Failed", "NotStarted"
      vm.sshable.cmd("common/bin/daemonizer 'sudo postgres/bin/install-wal-g c56a2315d3a63560f0227cb0bf902da8445963c7' install_wal-g")
    end

    nap 5
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
      unless (backup_label = postgres_server.timeline.latest_backup_label_before_target(target: postgres_server.resource.restore_target))
        fail "BUG: no backup found"
      end
      vm.sshable.cmd("common/bin/daemonizer 'sudo postgres/bin/initialize-database-from-backup #{backup_label}' initialize_database_from_backup")
    end

    nap 5
  end

  label def refresh_certificates
    vm.sshable.cmd("sudo -u postgres tee /dat/16/data/server.crt > /dev/null", stdin: postgres_server.resource.server_cert)
    vm.sshable.cmd("sudo -u postgres tee /dat/16/data/server.key > /dev/null", stdin: postgres_server.resource.server_cert_key)
    vm.sshable.cmd("sudo -u postgres chmod 600 /dat/16/data/server.key")

    when_initial_provisioning_set? do
      hop_configure
    end

    vm.sshable.cmd("sudo -u postgres pg_ctlcluster 16 main reload")
    hop_wait
  end

  label def configure
    case vm.sshable.cmd("common/bin/daemonizer --check configure_postgres")
    when "Succeeded"
      vm.sshable.cmd("common/bin/daemonizer --clean configure_postgres")

      when_initial_provisioning_set? do
        hop_update_superuser_password if postgres_server.primary?
        hop_wait_recovery_completion
      end

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
    vm.sshable.cmd("sudo -u postgres psql", stdin: commands)

    when_initial_provisioning_set? do
      hop_restart
    end
    hop_wait
  end

  label def restart
    vm.sshable.cmd("sudo postgres/bin/restart")

    when_initial_provisioning_set? do
      decr_initial_provisioning
    end
    hop_wait
  end

  label def wait_recovery_completion
    is_in_recovery = vm.sshable.cmd("sudo -u postgres psql -At -c 'SELECT pg_is_in_recovery()'").chomp == "t"

    if is_in_recovery
      is_wal_replay_paused = vm.sshable.cmd("sudo -u postgres psql -At -c 'SELECT pg_get_wal_replay_pause_state()'").chomp == "paused"
      if is_wal_replay_paused
        vm.sshable.cmd("sudo -u postgres psql -c 'SELECT pg_wal_replay_resume()'")
        is_in_recovery = false
      end
    end

    if !is_in_recovery
      timeline_id = Prog::Postgres::PostgresTimelineNexus.assemble(parent_id: postgres_server.timeline.id).id
      postgres_server.timeline_id = timeline_id
      postgres_server.timeline_access = "push"
      postgres_server.save_changes

      refresh_walg_credentials

      decr_initial_provisioning
      hop_configure
    end

    nap 5
  end

  label def wait
    when_refresh_certificates_set? do
      hop_refresh_certificates
    end

    when_update_superuser_password_set? do
      hop_update_superuser_password
    end

    nap 30
  end

  label def destroy
    decr_destroy

    strand.children.each { _1.destroy }
    vm.private_subnets.each { _1.incr_destroy }
    vm.incr_destroy
    postgres_server.destroy

    pop "postgres server is deleted"
  end

  def refresh_walg_credentials
    return if postgres_server.timeline.blob_storage.nil?

    walg_config = postgres_server.timeline.generate_walg_config
    vm.sshable.cmd("sudo -u postgres tee /etc/postgresql/wal-g.env > /dev/null", stdin: walg_config)
  end
end
