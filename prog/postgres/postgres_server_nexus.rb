# frozen_string_literal: true

require "forwardable"

require_relative "../../lib/util"

class Prog::Postgres::PostgresServerNexus < Prog::Base
  subject_is :postgres_server

  extend Forwardable
  def_delegators :postgres_server, :vm

  def self.assemble(resource_id:, timeline_id:, timeline_access:, representative_at: nil, exclude_host_ids: [])
    DB.transaction do
      ubid = PostgresServer.generate_ubid

      postgres_resource = PostgresResource[resource_id]
      boot_image = case postgres_resource.flavor
      when PostgresResource::Flavor::STANDARD then "postgres#{postgres_resource.version}-ubuntu-2204"
      when PostgresResource::Flavor::PARADEDB then "postgres#{postgres_resource.version}-paradedb-ubuntu-2204"
      when PostgresResource::Flavor::LANTERN then "postgres#{postgres_resource.version}-lantern-ubuntu-2204"
      else raise "Unknown PostgreSQL flavor: #{postgres_resource.flavor}"
      end

      vm_st = Prog::Vm::Nexus.assemble_with_sshable(
        "ubi",
        Config.postgres_service_project_id,
        location_id: postgres_resource.location_id,
        name: ubid.to_s,
        size: postgres_resource.target_vm_size,
        storage_volumes: [
          {encrypted: true, size_gib: 30},
          {encrypted: true, size_gib: postgres_resource.target_storage_size_gib}
        ],
        boot_image: boot_image,
        private_subnet_id: postgres_resource.private_subnet_id,
        enable_ip4: true,
        exclude_host_ids: exclude_host_ids
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

      Strand.create(prog: "Postgres::PostgresServerNexus", label: "start") { _1.id = postgres_server.id }
    end
  end

  def before_run
    when_destroy_set? do
      if strand.label != "destroy"
        hop_destroy
      elsif strand.stack.count > 1
        pop "operation is cancelled due to the destruction of the postgres server"
      end
    end
  end

  label def start
    nap 5 unless vm.strand.label == "wait"

    postgres_server.incr_initial_provisioning
    hop_bootstrap_rhizome
  end

  label def bootstrap_rhizome
    if postgres_server.primary?
      register_deadline("wait", 10 * 60)
    else
      register_deadline("wait", 120 * 60)
    end

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
      vm.sshable.cmd("common/bin/daemonizer 'sudo postgres/bin/initialize-empty-database #{postgres_server.resource.version}' initialize_empty_database")
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
      vm.sshable.cmd("common/bin/daemonizer 'sudo postgres/bin/initialize-database-from-backup #{postgres_server.resource.version} #{backup_label}' initialize_database_from_backup")
    end

    nap 5
  end

  label def refresh_certificates
    decr_refresh_certificates

    nap 5 if postgres_server.resource.server_cert.nil?

    ca_bundle = postgres_server.resource.ca_certificates
    vm.sshable.cmd("sudo tee /etc/ssl/certs/ca.crt > /dev/null", stdin: ca_bundle)
    vm.sshable.cmd("sudo tee /etc/ssl/certs/server.crt > /dev/null", stdin: postgres_server.resource.server_cert)
    vm.sshable.cmd("sudo tee /etc/ssl/certs/server.key > /dev/null", stdin: postgres_server.resource.server_cert_key)
    vm.sshable.cmd("sudo chgrp cert_readers /etc/ssl/certs/ca.crt && sudo chmod 640 /etc/ssl/certs/ca.crt")
    vm.sshable.cmd("sudo chgrp cert_readers /etc/ssl/certs/server.crt && sudo chmod 640 /etc/ssl/certs/server.crt")
    vm.sshable.cmd("sudo chgrp cert_readers /etc/ssl/certs/server.key && sudo chmod 640 /etc/ssl/certs/server.key")

    # MinIO cluster certificate rotation timelines are similar to postgres
    # servers' timelines. So we refresh the wal-g credentials which uses MinIO
    # certificates when we refresh the certificates of the postgres server.
    refresh_walg_credentials

    when_initial_provisioning_set? do
      hop_configure_prometheus
    end

    vm.sshable.cmd("sudo -u postgres pg_ctlcluster #{postgres_server.resource.version} main reload")
    vm.sshable.cmd("sudo systemctl reload pgbouncer")
    hop_wait
  end

  label def configure_prometheus
    web_config = <<CONFIG
tls_server_config:
  cert_file: /etc/ssl/certs/server.crt
  key_file: /etc/ssl/certs/server.key
CONFIG
    vm.sshable.cmd("sudo -u prometheus tee /home/prometheus/web-config.yml > /dev/null", stdin: web_config)

    metric_destinations = postgres_server.resource.metric_destinations.map {
      <<METRIC_DESTINATION
- url: '#{_1.url}'
  basic_auth:
    username: '#{_1.username}'
    password: '#{_1.password}'
METRIC_DESTINATION
    }.prepend("remote_write:").join("\n")

    prometheus_config = <<CONFIG
global:
  scrape_interval: 10s
  external_labels:
    ubicloud_resource_id: #{postgres_server.resource.ubid}
    ubicloud_resource_role: #{(postgres_server.id == postgres_server.resource.representative_server.id) ? "primary" : "standby"}

scrape_configs:
- job_name: node
  static_configs:
  - targets: ['localhost:9100']
    labels:
      instance: '#{postgres_server.ubid}'
- job_name: postgres
  static_configs:
  - targets: ['localhost:9187']
    labels:
      instance: '#{postgres_server.ubid}'
#{metric_destinations}
CONFIG
    vm.sshable.cmd("sudo -u prometheus tee /home/prometheus/prometheus.yml > /dev/null", stdin: prometheus_config)

    when_initial_provisioning_set? do
      vm.sshable.cmd("sudo systemctl enable --now postgres_exporter")
      vm.sshable.cmd("sudo systemctl enable --now node_exporter")
      vm.sshable.cmd("sudo systemctl enable --now prometheus")

      hop_configure
    end

    vm.sshable.cmd("sudo systemctl reload postgres_exporter || sudo systemctl restart postgres_exporter")
    vm.sshable.cmd("sudo systemctl reload node_exporter || sudo systemctl restart node_exporter")
    vm.sshable.cmd("sudo systemctl reload prometheus || sudo systemctl restart prometheus")

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
      vm.sshable.cmd("common/bin/daemonizer 'sudo postgres/bin/configure #{postgres_server.resource.version}' configure_postgres", stdin: JSON.generate(configure_hash))
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
      if retval&.dig("msg") == "postgres server is restarted"
        hop_run_post_installation_script if postgres_server.primary? && postgres_server.resource.flavor != PostgresResource::Flavor::STANDARD
        hop_wait
      end
      push self.class, frame, "restart"
    end

    hop_wait
  end

  label def run_post_installation_script
    command = <<~COMMAND
    set -ueo pipefail
    [[ -f /etc/postgresql-partners/post-installation-script ]] || { echo "Post-installation script not found. Exiting..."; exit 0; }
    sudo cp /etc/postgresql-partners/post-installation-script postgres/bin/post-installation-script
    sudo chown ubi:ubi postgres/bin/post-installation-script
    sudo chmod +x postgres/bin/post-installation-script
    postgres/bin/post-installation-script
    COMMAND

    vm.sshable.cmd(command)
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
    is_in_recovery = begin
      postgres_server.run_query("SELECT pg_is_in_recovery()").chomp == "t"
    rescue => ex
      raise ex unless ex.stderr.include?("Consistent recovery state has not been yet reached.")
      nap 5
    end

    if is_in_recovery
      is_wal_replay_paused = postgres_server.run_query("SELECT pg_get_wal_replay_pause_state()").chomp == "paused"
      if is_wal_replay_paused
        postgres_server.run_query("SELECT pg_wal_replay_resume()")
        is_in_recovery = false
      end
    end

    if !is_in_recovery
      timeline_id = Prog::Postgres::PostgresTimelineNexus.assemble(location_id: postgres_server.resource.location_id, parent_id: postgres_server.timeline.id).id
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
      decr_checkup
    end

    when_configure_prometheus_set? do
      decr_configure_prometheus
      hop_configure_prometheus
    end

    when_configure_set? do
      hop_configure
    end

    when_restart_set? do
      push self.class, frame, "restart"
    end

    nap 30
  end

  label def unavailable
    register_deadline("wait", 10 * 60)

    nap 0 if postgres_server.trigger_failover

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
      postgres_server.incr_restart
      hop_configure
    when "Failed", "NotStarted"
      vm.sshable.cmd("common/bin/daemonizer 'sudo pg_ctlcluster #{postgres_server.resource.version} main promote' promote_postgres")
      nap 0
    end

    nap 5
  end

  label def destroy
    decr_destroy

    strand.children.each { _1.destroy }
    vm.incr_destroy
    postgres_server.destroy

    pop "postgres server is deleted"
  end

  label def restart
    decr_restart
    vm.sshable.cmd("sudo postgres/bin/restart #{postgres_server.resource.version}")
    vm.sshable.cmd("sudo systemctl restart pgbouncer")
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
      return true if vm.sshable.cmd("sudo tail -n 5 /dat/#{postgres_server.resource.version}/data/pg_log/postgresql.log").include?("redo in progress")
    rescue
    end

    false
  end
end
