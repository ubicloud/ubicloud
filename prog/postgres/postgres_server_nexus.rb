# frozen_string_literal: true

require "forwardable"

require_relative "../../lib/util"

class Prog::Postgres::PostgresServerNexus < Prog::Base
  subject_is :postgres_server

  extend Forwardable
  def_delegators :postgres_server, :vm

  def self.assemble(resource_id:, timeline_id:, timeline_access:, representative_at: nil, exclude_host_ids: [], exclude_availability_zones: [], availability_zone: nil)
    DB.transaction do
      ubid = PostgresServer.generate_ubid

      postgres_resource = PostgresResource[resource_id]
      arch = Option::VmSizes.find { |it| it.name == postgres_resource.target_vm_size }.arch
      boot_image = if postgres_resource.location.aws?
        postgres_resource.location.pg_ami(postgres_resource.version, arch)
      else
        flavor_suffix = case postgres_resource.flavor
        when PostgresResource::Flavor::STANDARD then ""
        when PostgresResource::Flavor::PARADEDB then "-paradedb"
        when PostgresResource::Flavor::LANTERN then "#{postgres_resource.version}-lantern"
        else raise "Unknown PostgreSQL flavor: #{postgres_resource.flavor}"
        end

        "postgres#{flavor_suffix}-ubuntu-2204"
      end

      vm_st = Prog::Vm::Nexus.assemble_with_sshable(
        Config.postgres_service_project_id,
        sshable_unix_user: "ubi",
        location_id: postgres_resource.location_id,
        name: ubid.to_s,
        size: postgres_resource.target_vm_size,
        storage_volumes: [
          {encrypted: true, size_gib: 30, vring_workers: 1},
          {encrypted: true, size_gib: postgres_resource.target_storage_size_gib, vring_workers: 1}
        ],
        boot_image: boot_image,
        private_subnet_id: postgres_resource.private_subnet_id,
        enable_ip4: true,
        arch: arch,
        exclude_host_ids: exclude_host_ids,
        exclude_availability_zones: exclude_availability_zones,
        availability_zone: availability_zone
      )

      synchronization_status = representative_at ? "ready" : "catching_up"
      postgres_server = PostgresServer.create_with_id(
        ubid.to_uuid,
        resource_id: resource_id,
        timeline_id: timeline_id,
        timeline_access: timeline_access,
        representative_at: representative_at,
        synchronization_status: synchronization_status,
        vm_id: vm_st.id,
        version: postgres_resource.version
      )

      Strand.create_with_id(postgres_server.id, prog: "Postgres::PostgresServerNexus", label: "start")
    end
  end

  def before_run
    when_destroy_set? do
      is_destroying = ["destroy", nil].include?(postgres_server.resource&.strand&.label)

      if is_destroying || !postgres_server.taking_over?
        if !%w[destroy wait_children_destroy destroy_vm_and_pg].include?(strand.label)
          hop_destroy
        elsif strand.stack.count > 1
          pop "operation is cancelled due to the destruction of the postgres server"
        end
      else
        Clog.emit("Postgres server deletion is cancelled, because it is in the process of taking over the primary role")
        decr_destroy
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
    reap(:mount_data_disk, nap: 5)
  end

  label def mount_data_disk
    case vm.sshable.cmd("common/bin/daemonizer --check format_disk")
    when "Succeeded"
      storage_device_paths = postgres_server.storage_device_paths
      device_path = if storage_device_paths.count > 1
        vm.sshable.cmd("sudo mdadm --detail --scan | sudo tee -a /etc/mdadm/mdadm.conf")
        vm.sshable.cmd("sudo update-initramfs -u")
        "/dev/md0"
      else
        storage_device_paths.first
      end

      vm.sshable.cmd("sudo mkdir -p /dat")
      vm.sshable.cmd("sudo common/bin/add_to_fstab #{device_path} /dat ext4 defaults 0 0")
      vm.sshable.cmd("sudo mount #{device_path} /dat")

      hop_configure_walg_credentials
    when "Failed", "NotStarted"
      storage_device_paths = postgres_server.storage_device_paths
      if storage_device_paths.count == 1
        vm.sshable.cmd("common/bin/daemonizer 'sudo mkfs --type ext4 #{storage_device_paths.first}' format_disk")
      else
        vm.sshable.cmd("sudo mdadm --create --verbose /dev/md0 --level=0 --raid-devices=#{storage_device_paths.count} #{storage_device_paths.join(" ")}")
        vm.sshable.cmd("common/bin/daemonizer 'sudo mkfs --type ext4 /dev/md0' format_disk")
      end
    end

    nap 5
  end

  label def configure_walg_credentials
    postgres_server.refresh_walg_credentials
    hop_initialize_empty_database if postgres_server.primary?
    hop_initialize_database_from_backup
  end

  label def initialize_empty_database
    case vm.sshable.cmd("common/bin/daemonizer --check initialize_empty_database")
    when "Succeeded"
      hop_refresh_certificates
    when "Failed", "NotStarted"
      vm.sshable.cmd("common/bin/daemonizer 'sudo postgres/bin/initialize-empty-database #{postgres_server.version}' initialize_empty_database")
    end

    nap 5
  end

  label def initialize_database_from_backup
    case vm.sshable.cmd("common/bin/daemonizer --check initialize_database_from_backup")
    when "Succeeded"
      hop_refresh_certificates
    when "Failed", "NotStarted"
      backup_label = if postgres_server.standby? || postgres_server.read_replica?
        "LATEST"
      else
        postgres_server.timeline.latest_backup_label_before_target(target: postgres_server.resource.restore_target)
      end
      vm.sshable.cmd("common/bin/daemonizer 'sudo postgres/bin/initialize-database-from-backup #{postgres_server.version} #{backup_label}' initialize_database_from_backup")
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
    postgres_server.refresh_walg_credentials

    when_initial_provisioning_set? do
      hop_configure_metrics
    end

    vm.sshable.cmd("sudo -u postgres pg_ctlcluster #{postgres_server.version} main reload")
    vm.sshable.cmd("sudo systemctl reload pgbouncer@*.service")
    hop_wait
  end

  label def configure_metrics
    web_config = <<CONFIG
tls_server_config:
  cert_file: /etc/ssl/certs/server.crt
  key_file: /etc/ssl/certs/server.key
CONFIG
    vm.sshable.cmd("sudo -u prometheus tee /home/prometheus/web-config.yml > /dev/null", stdin: web_config)

    metric_destinations = postgres_server.resource.metric_destinations.map {
      <<METRIC_DESTINATION
- url: '#{it.url}'
  basic_auth:
    username: '#{it.username}'
    password: '#{it.password}'
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

    metrics_config = postgres_server.metrics_config
    metrics_dir = metrics_config[:metrics_dir]
    vm.sshable.cmd("mkdir -p #{metrics_dir}")
    vm.sshable.cmd("tee #{metrics_dir}/config.json > /dev/null", stdin: metrics_config.to_json)

    metrics_service = <<SERVICE
[Unit]
Description=PostgreSQL Metrics Collection
After=postgresql.service

[Service]
Type=oneshot
User=ubi
ExecStart=/home/ubi/common/bin/metrics-collector #{metrics_dir}
StandardOutput=journal
StandardError=journal
SERVICE
    vm.sshable.cmd("sudo tee /etc/systemd/system/postgres-metrics.service > /dev/null", stdin: metrics_service)

    metrics_interval = metrics_config[:interval] || "15s"

    metrics_timer = <<TIMER
[Unit]
Description=Run PostgreSQL Metrics Collection Periodically

[Timer]
OnBootSec=30s
OnUnitActiveSec=#{metrics_interval}
AccuracySec=1s

[Install]
WantedBy=timers.target
TIMER
    vm.sshable.cmd("sudo tee /etc/systemd/system/postgres-metrics.timer > /dev/null", stdin: metrics_timer)

    vm.sshable.cmd("sudo systemctl daemon-reload")

    when_initial_provisioning_set? do
      vm.sshable.cmd("sudo systemctl enable --now postgres_exporter")
      vm.sshable.cmd("sudo systemctl enable --now node_exporter")
      vm.sshable.cmd("sudo systemctl enable --now prometheus")
      vm.sshable.cmd("sudo systemctl enable --now postgres-metrics.timer")

      hop_setup_cloudwatch if postgres_server.timeline.aws? && postgres_server.resource.project.get_ff_aws_cloudwatch_logs
      hop_setup_hugepages
    end

    vm.sshable.cmd("sudo systemctl reload postgres_exporter || sudo systemctl restart postgres_exporter")
    vm.sshable.cmd("sudo systemctl reload node_exporter || sudo systemctl restart node_exporter")
    vm.sshable.cmd("sudo systemctl reload prometheus || sudo systemctl restart prometheus")

    hop_wait
  end

  label def setup_cloudwatch
    filepath = "/opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.d"
    filename = "001-ubicloud-config.json"
    config = <<CONFIG
{
  "logs": {
    "logs_collected": {
      "files": {
        "collect_list": [
          {
            "file_path": "/dat/#{postgres_server.version}/data/pg_log/postgresql.log",
            "log_group_name": "/#{postgres_server.ubid}/postgresql",
            "log_stream_name": "#{postgres_server.ubid}/postgresql",
            "timestamp_format": "%Y-%m-%d %H:%M:%S"
          },
          {
            "file_path": "/var/log/auth.log",
            "log_group_name": "/#{postgres_server.ubid}/auth",
            "log_stream_name": "#{postgres_server.ubid}/auth",
            "timestamp_format": "%Y-%m-%d %H:%M:%S"
          }
        ]
      }
    }
  }
}
CONFIG
    vm.sshable.cmd("sudo mkdir -p #{filepath}")
    vm.sshable.cmd("sudo tee #{filepath}/#{filename} > /dev/null", stdin: config)
    vm.sshable.cmd("sudo /opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl -a fetch-config -m ec2 -c file:#{filepath}/#{filename} -s")
    hop_setup_hugepages
  end

  label def setup_hugepages
    case vm.sshable.d_check("setup_hugepages")
    when "Succeeded"
      vm.sshable.d_clean("setup_hugepages")
      hop_configure
    when "Failed", "NotStarted"
      vm.sshable.d_run("setup_hugepages", "sudo", "postgres/bin/setup-hugepages")
    end

    nap 5
  end

  label def configure
    case vm.sshable.cmd("common/bin/daemonizer --check configure_postgres")
    when "Succeeded"
      vm.sshable.cmd("common/bin/daemonizer --clean configure_postgres")

      when_initial_provisioning_set? do
        hop_update_superuser_password if postgres_server.primary?
        hop_wait_catch_up if postgres_server.standby? || postgres_server.read_replica?
        hop_wait_recovery_completion
      end

      hop_wait_catch_up if postgres_server.standby? && postgres_server.synchronization_status != "ready"
      hop_wait
    when "Failed", "NotStarted"
      configure_hash = postgres_server.configure_hash
      vm.sshable.cmd("common/bin/daemonizer 'sudo postgres/bin/configure #{postgres_server.version}' configure_postgres", stdin: JSON.generate(configure_hash))
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
    nap 30 unless postgres_server.lsn_caught_up

    hop_wait if postgres_server.read_replica?

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
      postgres_server.switch_to_new_timeline

      hop_configure
    end

    nap 5
  end

  label def wait
    decr_initial_provisioning

    when_fence_set? do
      hop_fence
    end

    when_unplanned_take_over_set? do
      hop_prepare_for_unplanned_take_over
    end

    when_planned_take_over_set? do
      hop_prepare_for_planned_take_over
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

    when_configure_metrics_set? do
      decr_configure_metrics
      hop_configure_metrics
    end

    when_configure_set? do
      decr_configure
      hop_configure
    end

    when_restart_set? do
      push self.class, frame, "restart"
    end

    when_promote_set? do
      postgres_server.switch_to_new_timeline
      decr_promote
      hop_taking_over
    end

    when_refresh_walg_credentials_set? do
      decr_refresh_walg_credentials
      postgres_server.refresh_walg_credentials
    end

    if postgres_server.read_replica? && postgres_server.resource.parent
      nap 60 if postgres_server.lsn_caught_up

      lsn = postgres_server.current_lsn
      previous_lsn = strand.stack.first["lsn"]
      # The first time we are behind the primary, so, we'll just record the info
      # and nap
      unless previous_lsn
        update_stack_lsn(lsn)
        nap 15 * 60
      end

      if postgres_server.lsn_diff(lsn, previous_lsn) > 0
        update_stack_lsn(lsn)
        # Even if it is lagging, it has applied new wal files, so, we should
        # give it a chance to catch up
        decr_recycle
        nap 15 * 60
      else
        # It has not applied any new wal files while has been napping for the
        # last 15 minutes, so, there should be something wrong, we are recycling
        postgres_server.incr_recycle unless postgres_server.recycle_set?
      end
      nap 60
    end

    nap 6 * 60 * 60
  end

  label def unavailable
    register_deadline("wait", 10 * 60)

    nap 0 if postgres_server.resource.ongoing_failover? || postgres_server.trigger_failover(mode: "unplanned")

    reap(fallthrough: true)
    nap 5 unless strand.children_dataset.where(prog: "Postgres::PostgresServerNexus", label: "restart").empty?

    if available?
      decr_checkup
      hop_wait
    end

    bud self.class, {}, :restart
    nap 5
  end

  label def fence
    decr_fence

    # Use multiple checkpoints so the final shutdown checkpoint is
    # brief.
    #
    # The mechanism is to progressively reduce dirty buffers. The
    # first `CHECKPOINT` may take a long time, during which more
    # buffers become dirty. The next CHECKPOINT runs faster: even with
    # a "long" first CHECKPOINT, the number of dirty buffers generated
    # in the interim will be far fewer.
    #
    # By the third checkpoint, runtime is usually 1-2
    # seconds. Shutdown then proceeds with only a short final
    # checkpoint.
    #
    # Closely spaced checkpoints make UPDATEs more expensive due to
    # full-page write amplification. After each checkpoint, the first
    # change to a page requires writing a full 8KB copy instead of a
    # smaller incremental WAL record. This short-term slowdown (a few
    # minutes at worst) and increased WAL volume are accepted in order
    # to avoid stopping all workloads for a long shutdown checkpoint.
    postgres_server.run_query("CHECKPOINT; CHECKPOINT; CHECKPOINT;")
    postgres_server.vm.sshable.cmd("sudo postgres/bin/lockout #{postgres_server.version}")
    postgres_server.vm.sshable.cmd("sudo pg_ctlcluster #{postgres_server.version} main stop -m smart")

    hop_wait_in_fence
  end

  label def wait_in_fence
    when_unfence_set? do
      decr_unfence
      postgres_server.incr_configure
      postgres_server.incr_restart
      hop_wait
    end

    nap 60
  end

  label def prepare_for_unplanned_take_over
    decr_unplanned_take_over

    representative_server = postgres_server.resource.representative_server

    begin
      representative_server.vm.sshable.cmd("sudo pg_ctlcluster #{postgres_server.version} main stop -m immediate")
    rescue *Sshable::SSH_CONNECTION_ERRORS, Sshable::SshError
    end

    representative_server.incr_destroy

    hop_taking_over
  end

  label def prepare_for_planned_take_over
    decr_planned_take_over

    postgres_server.resource.representative_server.incr_fence
    hop_wait_fencing_of_old_primary
  end

  label def wait_fencing_of_old_primary
    nap 0 if postgres_server.resource.representative_server.strand.label != "wait_in_fence"

    postgres_server.resource.representative_server.incr_destroy
    hop_taking_over
  end

  label def taking_over
    if postgres_server.read_replica?
      postgres_server.update(representative_at: Time.now)
      postgres_server.resource.servers.each(&:incr_configure_metrics)
      postgres_server.resource.incr_refresh_dns_record
      hop_configure
    end

    case vm.sshable.cmd("common/bin/daemonizer --check promote_postgres")
    when "Succeeded"
      postgres_server.update(timeline_access: "push", representative_at: Time.now, synchronization_status: "ready")
      postgres_server.resource.incr_refresh_dns_record
      postgres_server.resource.servers.each(&:incr_configure)
      postgres_server.resource.servers.each(&:incr_configure_metrics)
      postgres_server.resource.servers.each(&:incr_restart)
      postgres_server.resource.servers.reject(&:primary?).each { it.update(synchronization_status: "catching_up") }
      hop_configure
    when "Failed", "NotStarted"
      vm.sshable.cmd("common/bin/daemonizer 'sudo postgres/bin/promote #{postgres_server.version}' promote_postgres")
      nap 0
    end

    nap 5
  end

  label def destroy
    decr_destroy
    Semaphore.incr(strand.children_dataset.exclude(prog: "Postgres::PostgresServerNexus").select(:id), "destroy")
    hop_wait_children_destroy
  end

  label def wait_children_destroy
    reap(:destroy_vm_and_pg, nap: 30)
  end

  label def destroy_vm_and_pg
    vm.incr_destroy
    postgres_server.destroy

    pop "postgres server is deleted"
  end

  label def restart
    decr_restart
    vm.sshable.cmd("sudo postgres/bin/restart #{postgres_server.version}")
    vm.sshable.cmd("sudo systemctl restart pgbouncer@*.service")
    pop "postgres server is restarted"
  end

  def available?
    vm.sshable.invalidate_cache_entry

    # Don't declare unavailability if we are upgrading.
    return true if postgres_server.resource.version != postgres_server.resource.target_version && postgres_server == postgres_server.resource.upgrade_candidate_server

    begin
      postgres_server.run_query("SELECT 1")
      return true
    rescue
    end

    # Do not declare unavailability if Postgres is in crash recovery
    begin
      return true if vm.sshable.cmd("sudo tail -n 5 /dat/#{postgres_server.version}/data/pg_log/postgresql.log").include?("redo in progress")
    rescue
    end

    false
  end

  def update_stack_lsn(lsn)
    current_frame = strand.stack.first
    current_frame["lsn"] = lsn
    strand.modified!(:stack)
    strand.save_changes
  end
end
