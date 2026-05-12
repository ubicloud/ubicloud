# frozen_string_literal: true

require "forwardable"

require_relative "../../lib/util"

class Prog::Postgres::PostgresServerNexus < Prog::Base
  subject_is :postgres_server

  extend Forwardable

  def_delegators :postgres_server, :vm, :resource

  def self.assemble(resource_id:, timeline_id:, timeline_access:, is_representative: false, exclude_host_ids: [], exclude_availability_zones: [], availability_zone: nil, exclude_data_centers: [])
    DB.transaction do
      ubid = PostgresServer.generate_ubid

      postgres_resource = PostgresResource[resource_id]
      # For read replicas and representative servers (initial creation), use
      # target_version. For standbys, match the representative server's version
      # so in-place upgrades work correctly.
      server_version = if is_representative || postgres_resource.read_replica?
        postgres_resource.target_version
      else
        postgres_resource.version
      end

      arch = Option::VmSizes.find { it.name == postgres_resource.target_vm_size.gsub("hobby", "burstable") }.arch
      boot_image = postgres_resource.boot_image(server_version, arch)

      vm_st = Prog::Vm::Nexus.assemble_with_sshable(
        Config.postgres_service_project_id,
        sshable_unix_user: "ubi",
        location_id: postgres_resource.location_id,
        name: ubid.to_s,
        size: postgres_resource.target_vm_size.gsub("hobby", "burstable"),
        storage_volumes: [
          {encrypted: true, size_gib: 16, vring_workers: 1},
          {encrypted: true, size_gib: postgres_resource.target_storage_size_gib, vring_workers: 1},
        ],
        boot_image:,
        private_subnet_id: postgres_resource.private_subnet_id,
        enable_ip4: true,
        arch:,
        allow_private_subnet_in_other_project: true,
        exclude_host_ids:,
        exclude_availability_zones:,
        availability_zone:,
        exclude_data_centers:,
        swap_size_bytes: postgres_resource.target_vm_size.start_with?("hobby") ? 4 * 1024 * 1024 * 1024 : nil,
      )

      synchronization_status = (is_representative && !postgres_resource.read_replica?) ? "ready" : "catching_up"
      postgres_server = PostgresServer.create_with_id(
        ubid.to_uuid,
        resource_id:,
        timeline_id:,
        timeline_access:,
        is_representative:,
        synchronization_status:,
        vm_id: vm_st.id,
        version: server_version,
      )

      vm_st.subject.add_vm_firewall(postgres_resource.internal_firewall)

      Strand.create_with_id(postgres_server, prog: "Postgres::PostgresServerNexus", label: "start")
    end
  end

  def before_run
    when_destroy_set? do
      is_resource_destroying = resource.nil? || resource.destroy_set? || resource.destroying_set?

      if !is_resource_destroying && postgres_server.is_representative
        Clog.emit("Postgres server deletion is cancelled, because it is the representative server of an alive resource; flip is_representative=false (via a proper failover) before destroying.", {ubid: postgres_server.ubid, resource_ubid: resource.ubid})
        decr_destroy
        return
      end

      if !is_resource_destroying && postgres_server.taking_over?
        Clog.emit("Postgres server deletion is cancelled, because it is in the process of taking over the primary role")
        decr_destroy
        return
      end

      hop_destroy unless destroying_set?
    end
  end

  label def start
    nap 5 unless vm.strand.label == "wait"

    postgres_server.incr_initial_provisioning
    hop_bootstrap_rhizome
  end

  label def bootstrap_rhizome
    register_deadline("wait", 10 * 60)

    bud Prog::BootstrapRhizome, {"target_folder" => "postgres", "subject_id" => vm.id, "user" => "ubi", "no_bundler_install" => true}
    hop_wait_bootstrap_rhizome
  end

  label def wait_bootstrap_rhizome
    reap(:mount_data_disk, nap: 5)
  end

  label def mount_data_disk
    storage_device_paths = postgres_server.storage_device_paths
    case vm.sshable.d_check("format_disk")
    when "Succeeded"
      device_path = if storage_device_paths.count > 1
        vm.sshable.cmd("sudo mdadm --detail --scan | sudo tee -a /etc/mdadm/mdadm.conf")
        vm.sshable.cmd("sudo update-initramfs -u")
        "/dev/md0"
      else
        storage_device_paths.first
      end

      # ext4 defaults to reserving 5% of disk for root, cap this to 50 GiB
      blocks_per_gib = 262144 # number of 4 KiB blocks per GiB
      reserve_blocks = [(postgres_server.storage_size_gib * blocks_per_gib * 0.05).to_i, 50 * blocks_per_gib].min
      vm.sshable.cmd("sudo tune2fs :path -r :reserve_blocks", path: device_path, reserve_blocks:)

      vm.sshable.cmd("sudo mkdir -p /dat")
      vm.sshable.cmd("sudo common/bin/add_to_fstab :device_path /dat ext4 defaults 0 0", device_path:)
      vm.sshable.cmd("sudo mount :device_path /dat", device_path:)

      hop_run_init_script
    when "Failed", "NotStarted"
      if storage_device_paths.count == 1
        vm.sshable.d_run("format_disk", "sudo", "mkfs", "--type", "ext4", storage_device_paths.first)
      else
        vm.sshable.cmd("sudo mdadm --create --verbose /dev/md0 --level=0 --raid-devices=:count :shelljoin_storage_device_paths",
          count: storage_device_paths.count,
          shelljoin_storage_device_paths: storage_device_paths)
        vm.sshable.d_run("format_disk", "sudo", "mkfs", "--type", "ext4", "/dev/md0")
      end
    end

    nap 5
  end

  label def run_init_script
    hop_configure_walg_credentials unless resource.init_script
    case vm.sshable.d_check("run_init_script")
    when "Succeeded"
      hop_configure_walg_credentials
    when "Failed", "NotStarted"
      vm.sshable.cmd("sudo tee postgres/bin/init_script.sh > /dev/null", stdin: resource.init_script.init_script.gsub("\r\n", "\n"))
      vm.sshable.cmd("sudo chmod +x postgres/bin/init_script.sh")
      role = if postgres_server.primary?
        "primary"
      elsif postgres_server.read_replica?
        "read_replica"
      elsif postgres_server.standby?
        "standby"
      else
        "restore"
      end
      vm.sshable.d_run("run_init_script", "./postgres/bin/init_script.sh", role, stdin: resource.name)
    end

    nap 5
  end

  label def configure_walg_credentials
    postgres_server.attach_s3_policy_if_needed
    postgres_server.refresh_walg_credentials
    hop_initialize_empty_database if postgres_server.primary?
    hop_initialize_database_from_backup
  end

  label def initialize_empty_database
    case vm.sshable.d_check("initialize_empty_database")
    when "Succeeded"
      hop_refresh_certificates
    when "Failed", "NotStarted"
      strict_overcommit = resource.skip_strict_memory_overcommit_set? ? "false" : "true"
      vm.sshable.d_run("initialize_empty_database", "sudo", "postgres/bin/initialize-empty-database", postgres_server.version, strict_overcommit)
    end

    nap 5
  end

  label def initialize_database_from_backup
    case vm.sshable.d_check("initialize_database_from_backup")
    when "Succeeded"
      Page.from_tag_parts("PGInitializeDatabaseFromBackupFailed", postgres_server.id)&.incr_resolve
      delete_from_stack("disk_usage", "initialize_database_from_backup_try_count")
      hop_refresh_certificates
    when "InProgress"
      disk_usage = postgres_server.data_disk_usage
      previous_disk_usage = frame["disk_usage"] || 0
      if disk_usage > previous_disk_usage
        update_stack({"disk_usage" => disk_usage})
        register_deadline("wait", 10 * 60, allow_extension: 24 * 60 * 60)
      end
    when "Failed", "NotStarted"
      previous_try_count = frame["initialize_database_from_backup_try_count"] || 0
      if previous_try_count >= 3
        Prog::PageNexus.assemble("#{postgres_server.ubid} initialize database from backup failed after 3 attempts",
          ["PGInitializeDatabaseFromBackupFailed", postgres_server.id], postgres_server.ubid)
      end
      update_stack({"initialize_database_from_backup_try_count" => previous_try_count + 1})

      backup_label = if postgres_server.standby? || postgres_server.read_replica? || postgres_server.unarchive_set?
        "LATEST"
      else
        postgres_server.timeline.latest_backup_label_before_target(target: resource.restore_target)
      end
      recovery_mode = if postgres_server.standby? || postgres_server.read_replica?
        "standby"
      else
        # PITR (restore_target) and unarchive terminate recovery once WAL is
        # exhausted; no live primary to follow.
        "recovery"
      end
      strict_overcommit = resource.skip_strict_memory_overcommit_set? ? "false" : "true"
      vm.sshable.d_run("initialize_database_from_backup", "sudo", "postgres/bin/initialize-database-from-backup", postgres_server.version, backup_label, strict_overcommit, recovery_mode)
    end

    nap 5
  end

  label def refresh_certificates
    decr_refresh_certificates

    nap 5 if resource.server_cert.nil?

    client_ca_bundle = [resource.client_ca_certificates, resource.trusted_ca_certs].compact.join("\n")

    vm.sshable.write_file("/etc/ssl/certs/ca.crt", client_ca_bundle)
    vm.sshable.write_file("/etc/ssl/certs/server-ca.crt", resource.ca_certificates)
    vm.sshable.write_file("/etc/ssl/certs/server.crt", resource.server_cert)
    vm.sshable.write_file("/etc/ssl/certs/server.key", resource.server_cert_key)
    vm.sshable.write_file("/etc/ssl/certs/client.crt", resource.client_cert)
    vm.sshable.write_file("/etc/ssl/certs/client.key", resource.client_cert_key)

    vm.sshable.cmd("sudo chgrp cert_readers /etc/ssl/certs/ca.crt && sudo chmod 640 /etc/ssl/certs/ca.crt")
    vm.sshable.cmd("sudo chgrp cert_readers /etc/ssl/certs/server-ca.crt && sudo chmod 640 /etc/ssl/certs/server-ca.crt")
    vm.sshable.cmd("sudo chgrp cert_readers /etc/ssl/certs/server.crt && sudo chmod 640 /etc/ssl/certs/server.crt")
    vm.sshable.cmd("sudo chgrp cert_readers /etc/ssl/certs/server.key && sudo chmod 640 /etc/ssl/certs/server.key")
    vm.sshable.cmd("sudo chgrp cert_readers /etc/ssl/certs/client.crt && sudo chmod 640 /etc/ssl/certs/client.crt")
    vm.sshable.cmd("sudo chgrp cert_readers /etc/ssl/certs/client.key && sudo chmod 640 /etc/ssl/certs/client.key")

    # MinIO cluster certificate rotation timelines are similar to postgres
    # servers' timelines. So we refresh the wal-g credentials which uses MinIO
    # certificates when we refresh the certificates of the postgres server.
    postgres_server.refresh_walg_credentials

    when_initial_provisioning_set? do
      hop_configure_metrics
    end

    vm.sshable.cmd("sudo -u postgres pg_ctlcluster :version main reload", version:)
    vm.sshable.cmd("sudo systemctl reload pgbouncer@*.service")
    hop_wait
  end

  label def configure_metrics
    web_config = <<CONFIG
tls_server_config:
  cert_file: /etc/ssl/certs/server.crt
  key_file: /etc/ssl/certs/server.key
CONFIG
    vm.sshable.write_file("/home/prometheus/web-config.yml", web_config, user: "prometheus")

    metric_destinations = resource.metric_destinations.map {
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
    ubicloud_resource_id: #{resource.ubid}
    ubicloud_resource_role: #{(postgres_server.id == resource.representative_server.id) ? "primary" : "standby"}

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
    vm.sshable.write_file("/home/prometheus/prometheus.yml", prometheus_config, user: "prometheus")

    metrics_config = postgres_server.metrics_config
    metrics_dir = metrics_config[:metrics_dir]
    vm.sshable.cmd("mkdir -p :metrics_dir", metrics_dir:)
    vm.sshable.write_file("#{metrics_dir}/config.json", metrics_config.to_json, user: :current)

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
    vm.sshable.write_file("/etc/systemd/system/postgres-metrics.service", metrics_service)

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
    vm.sshable.write_file("/etc/systemd/system/postgres-metrics.timer", metrics_timer)

    vm.sshable.cmd("sudo mkdir -p /var/lib/node_exporter")
    vm.sshable.cmd("sudo chown ubi:ubi /var/lib/node_exporter")

    pg_metrics_service = <<SERVICE
[Unit]
Description=Postgres Metrics Collection
After=postgresql.service

[Service]
Type=oneshot
User=ubi
ExecStart=/home/ubi/postgres/bin/collect-pg-metrics #{postgres_server.version}
StandardOutput=journal
StandardError=journal
SERVICE
    vm.sshable.write_file("/etc/systemd/system/pg-collect-metrics.service", pg_metrics_service)

    pg_metrics_timer = <<TIMER
[Unit]
Description=Run pg-collect-metrics periodically

[Timer]
OnBootSec=30s
OnUnitActiveSec=30s
AccuracySec=1s

[Install]
WantedBy=timers.target
TIMER
    vm.sshable.write_file("/etc/systemd/system/pg-collect-metrics.timer", pg_metrics_timer)

    vm.sshable.cmd("sudo systemctl daemon-reload")

    when_initial_provisioning_set? do
      vm.sshable.cmd("sudo systemctl enable --now postgres_exporter")
      vm.sshable.cmd("sudo systemctl enable --now node_exporter")
      vm.sshable.cmd("sudo systemctl enable --now prometheus")
      vm.sshable.cmd("sudo systemctl enable --now postgres-metrics.timer")
      vm.sshable.cmd("sudo systemctl enable --now pg-collect-metrics.timer")
      vm.sshable.cmd("sudo systemctl enable --now wal-g") if postgres_server.timeline.blob_storage && !resource.use_old_walg_command_set?

      hop_configure_logs
    end

    vm.sshable.cmd("sudo systemctl reload postgres_exporter || sudo systemctl restart postgres_exporter")
    vm.sshable.cmd("sudo systemctl reload node_exporter || sudo systemctl restart node_exporter")
    vm.sshable.cmd("sudo systemctl reload prometheus || sudo systemctl restart prometheus")

    hop_wait
  end

  label def configure_logs
    case vm.sshable.d_check("configure_logs")
    when "Succeeded"
      vm.sshable.d_clean("configure_logs")
      when_initial_provisioning_set? do
        hop_setup_cloudwatch if postgres_server.timeline.aws? && resource.project.get_ff_aws_cloudwatch_logs
        hop_setup_hugepages
      end
      hop_wait
    when "Failed", "NotStarted"
      vm.sshable.d_run("configure_logs", "/home/ubi/postgres/bin/configure-logs", stdin: postgres_server.logs_config.to_json)
    end
    nap 5
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
            "file_path": "/dat/#{postgres_server.version}/data/pg_log/postgresql-*.log",
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
    vm.sshable.cmd("sudo mkdir -p :filepath", filepath:)
    vm.sshable.write_file("#{filepath}/#{filename}", config)
    vm.sshable.cmd("sudo /opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl -a fetch-config -m ec2 -c file::filepath/:filename -s", filepath:, filename:)
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
    case vm.sshable.d_check("configure_postgres")
    when "Succeeded"
      vm.sshable.d_clean("configure_postgres")

      when_initial_provisioning_set? do
        hop_update_superuser_password if postgres_server.primary?
        hop_wait_catch_up if postgres_server.standby? || postgres_server.read_replica?
        hop_wait_recovery_completion
      end

      hop_wait_catch_up if postgres_server.standby? && postgres_server.synchronization_status != "ready"

      if postgres_server.primary?
        resource.servers.select { it.standby? && it.synchronization_status == "ready" && it.physical_slot_ready_id != postgres_server.id }.each do |standby|
          standby.incr_use_physical_slot
          standby.incr_configure
        end
      end

      hop_wait
    when "Failed", "NotStarted"
      if postgres_server.use_physical_slot_set?
        postgres_server.update(physical_slot_ready_id: postgres_server.resource.representative_server.id)
        decr_use_physical_slot
      end
      configure_hash = postgres_server.configure_hash
      vm.sshable.d_run("configure_postgres", "sudo", "postgres/bin/configure", postgres_server.version, stdin: JSON.generate(configure_hash))
    end

    nap 5
  end

  label def update_superuser_password
    decr_update_superuser_password

    encrypted_password = DB.synchronize do |conn|
      # This uses PostgreSQL's PQencryptPasswordConn function, but it needs a connection, because
      # the encryption is made by PostgreSQL, not by control plane. We use our own control plane
      # database to do the encryption.
      conn.encrypt_password(resource.superuser_password, "postgres", "scram-sha-256")
    end
    commands = DB[<<SQL, encrypted_password:]
BEGIN;
SET LOCAL log_statement = 'none';
ALTER ROLE postgres WITH PASSWORD :encrypted_password;
COMMIT;
SQL
    postgres_server.run_query(commands)

    when_initial_provisioning_set? do
      if postgres_server.paradedb_and_primary?
        postgres_server.vm.sshable.cmd(<<CMD, version: postgres_server.version)
set -ueo pipefail
sudo apt-get install /var/cache/paradedb/postgresql-:version-pg-analytics.deb
sudo apt-get install /var/cache/paradedb/postgresql-:version-pg-search.deb
CMD
      end

      hop_run_post_installation_script
    end

    hop_wait
  end

  label def run_post_installation_script
    case vm.sshable.d_check("post_installation_script")
    when "Succeeded"
      if postgres_server.paradedb_and_primary?
        postgres_server.run_query(<<SQL)
CREATE EXTENSION IF NOT EXISTS pg_cron;
CREATE EXTENSION IF NOT EXISTS pg_search;
CREATE EXTENSION IF NOT EXISTS pg_analytics;
CREATE EXTENSION IF NOT EXISTS vector;
SQL
      end

      hop_wait
    when "Failed", "NotStarted"
      vm.sshable.d_run("post_installation_script", "sudo", "postgres/bin/post-installation-script")
    end

    nap 1
  end

  label def wait_catch_up
    if postgres_server.lsn_caught_up
      delete_from_stack("previous_lsn", "previous_disk_usage")
      hop_wait if postgres_server.read_replica?

      postgres_server.update(synchronization_status: "ready")

      resource.representative_server.incr_configure
      hop_wait_synchronization if resource.ha_type == PostgresResource::HaType::SYNC
      hop_wait
    end

    if (current_lsn = postgres_server.last_known_lsn)
      previous_lsn = strand.stack.first["previous_lsn"]
      if previous_lsn.nil? || postgres_server.lsn_diff(current_lsn, previous_lsn) > 0
        update_stack({"previous_lsn" => current_lsn})
        register_deadline("wait", 10 * 60, allow_extension: 24 * 60 * 60)
      end
    else
      disk_usage = postgres_server.data_disk_usage
      previous_disk_usage = strand.stack.first["previous_disk_usage"] || 0
      if disk_usage > previous_disk_usage
        update_stack({"previous_disk_usage" => disk_usage})
        register_deadline("wait", 10 * 60, allow_extension: 24 * 60 * 60)
      end
    end
    nap 30
  end

  label def wait_synchronization
    query = DB["SELECT sync_state FROM pg_stat_replication WHERE application_name = :ubid", ubid: postgres_server.ubid]
    sync_state = resource.representative_server.run_query(query).chomp
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
      decr_initial_provisioning
      hop_configure
    end

    nap 5
  end

  label def wait
    decr_initial_provisioning

    when_fence_set? do
      hop_fence
    end

    when_lockout_set? do
      hop_lockout
    end

    when_unplanned_take_over_set? do
      register_deadline("wait", 5 * 60)
      hop_prepare_for_unplanned_take_over
    end

    when_planned_take_over_set? do
      register_deadline("wait", 5 * 60)
      hop_prepare_for_planned_take_over
    end

    when_refresh_certificates_set? do
      hop_refresh_certificates
    end

    when_update_superuser_password_set? do
      hop_update_superuser_password
    end

    when_checkup_set? do
      unless available?
        register_deadline("wait", 5 * 60)
        hop_unavailable
      end

      decr_checkup
    end

    when_configure_set? do
      decr_configure
      hop_configure
    end

    when_restart_set? do
      register_deadline("complete_restart", 2 * 60)
      if daemonized_restart
        decr_restart
        unregister_deadline("complete_restart")
      else
        nap 1
      end
    end

    when_configure_metrics_set? do
      decr_configure_metrics
      hop_configure_metrics
    end

    when_configure_logs_set? do
      decr_configure_logs
      hop_configure_logs
    end

    when_promote_read_replica_set? do
      decr_promote_read_replica
      register_deadline("wait", 10 * 60)
      hop_promote_read_replica
    end

    when_refresh_walg_credentials_set? do
      decr_refresh_walg_credentials
      postgres_server.refresh_walg_credentials
    end

    when_configure_s3_new_timeline_set? do
      decr_configure_s3_new_timeline
      postgres_server.attach_s3_policy_if_needed
      postgres_server.refresh_walg_credentials
    end

    if postgres_server.read_replica? && resource.parent
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
        decr_recycle_lagging_read_replica
        nap 15 * 60
      else
        # It has not applied any new wal files while has been napping for the
        # last 15 minutes, so, there should be something wrong, we are recycling
        postgres_server.incr_recycle_lagging_read_replica unless postgres_server.recycle_lagging_read_replica_set?
      end
      nap 60
    end

    nap 6 * 60 * 60
  end

  label def unavailable
    when_lockout_set? do
      hop_lockout
    end

    nap 0 if resource.ongoing_failover? || postgres_server.trigger_failover(mode: "unplanned")

    when_configure_set? do
      decr_configure
      hop_configure
    end

    if available?
      decr_checkup
      decr_recycle_unavailable_server
      hop_wait
    end

    postgres_server.incr_recycle_unavailable_server unless postgres_server.recycle_unavailable_server_set?

    daemonized_restart
    nap 5
  end

  label def fence
    decr_fence

    when_lockout_set? do
      hop_lockout
    end

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
    postgres_server.vm.sshable.cmd("sudo postgres/bin/lockout :version", version:)
    postgres_server.vm.sshable.cmd("sudo pg_ctlcluster :version main stop -m smart", version:)
    postgres_server.vm.sshable.cmd("sudo systemctl stop postgres-metrics.timer")

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

    resource.representative_server.incr_lockout

    hop_wait_representative_lockout
  end

  label def wait_representative_lockout
    hop_taking_over if resource.representative_server.strand.label == "wait_locked_out"

    nap 1
  end

  label def lockout
    decr_lockout

    resource.lockout_mechanisms.each do |mechanism|
      bud Prog::Postgres::PostgresLockout, {"mechanism" => mechanism}
    end

    hop_wait_lockout_attempt
  end

  label def wait_lockout_attempt
    reaper = lambda do |child|
      if child.exitval == "lockout_succeeded"
        update_stack({"lockout_succeeded" => true})
      end
    end

    reap(:wait_locked_out, fallthrough: true, reaper:, prog: "Postgres::PostgresLockout")
    hop_wait_locked_out if strand.stack.first["lockout_succeeded"]

    nap 0.5
  end

  label def wait_locked_out
    nap 24 * 60 * 60
  end

  label def prepare_for_planned_take_over
    decr_planned_take_over

    resource.representative_server.incr_fence
    hop_wait_fencing_of_old_primary
  end

  label def wait_fencing_of_old_primary
    representative_server = resource.representative_server
    hop_taking_over if representative_server.strand.label == "wait_in_fence"

    if strand.stack.first["deadline_at"] && Time.now > Time.parse(strand.stack.first["deadline_at"].to_s)
      representative_server.incr_lockout
      hop_wait_representative_lockout
    end

    nap 1
  end

  label def promote_read_replica
    case vm.sshable.d_check("promote_postgres")
    when "Succeeded"
      vm.sshable.d_clean("promote_postgres")
      resource.server_incr("configure", "configure_metrics", "configure_logs")
      hop_configure
    when "NotStarted", "Failed"
      vm.sshable.d_run("promote_postgres", "sudo", "postgres/bin/promote", postgres_server.version)
    end

    nap 5
  end

  label def taking_over
    if postgres_server.read_replica?
      resource.representative_server.update(is_representative: false)
      postgres_server.reload.update(is_representative: true, synchronization_status: "ready")
      resource.server_incr("configure_metrics", "configure_logs")
      resource.incr_refresh_dns_record
      hop_configure
    end

    case vm.sshable.d_check("promote_postgres")
    when "Succeeded"
      Page.from_tag_parts("PGPromotionFailed", postgres_server.id)&.incr_resolve
      resource.representative_server.update(is_representative: false)
      resource.representative_server.incr_destroy
      postgres_server.update(timeline_access: "push", is_representative: true, synchronization_status: "ready")
      resource.incr_refresh_dns_record
      resource.server_incr("configure", "configure_metrics", "configure_logs")
      resource.servers.reject(&:primary?).each { it.update(synchronization_status: "catching_up") }
      hop_configure
    when "Failed"
      vm.sshable.d_run("promote_postgres", "sudo", "postgres/bin/promote", postgres_server.version)
      nap 0
    when "NotStarted"
      vm.sshable.d_run("promote_postgres", "sudo", "postgres/bin/promote", postgres_server.version)
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
    # Best-effort: capture kernel logs before destroying the VM.
    # This preserves OOM kill evidence that otelcol may not have shipped.
    begin
      dmesg = vm.sshable.cmd("sudo dmesg --time-format iso | tail -200", timeout: 10, log: false)
      Clog.emit("dmesg before destroy", {dmesg_capture: {server: postgres_server.ubid, output: dmesg}})
    rescue *Sshable::SSH_CONNECTION_ERRORS, Sshable::SshError
      nil
    end

    vm.incr_destroy
    representative_server = resource&.representative_server
    postgres_server.destroy
    representative_server&.incr_configure

    pop "postgres server is deleted"
  end

  def available?
    vm.sshable.invalidate_cache_entry

    # Don't declare unavailability if we are upgrading.
    return true if resource.version != resource.target_version && postgres_server == resource.upgrade_candidate_server

    begin
      postgres_server.run_query("SELECT 1")
      return true
    rescue
      nil
    end
    # Do not declare unavailability if Postgres is in crash recovery.
    # Check if log file was modified recently and last 50 lines contain recovery messages.
    begin
      log_output = vm.sshable.cmd("sudo find /dat/:version/data/pg_log/ -name 'postgresql-*.log' -mmin -5 -exec tail -n 50 {} \\; | grep -e 'redo in progress' -e 'Consistent recovery state has not been yet reached'", version:)
      return true unless log_output.empty?
    rescue
      nil
    end

    false
  end

  def update_stack_lsn(lsn)
    update_stack({"lsn" => lsn})
  end

  def version
    postgres_server.version
  end

  def daemonized_restart
    case vm.sshable.d_check("postgres_restart")
    when "Succeeded"
      vm.sshable.d_clean("postgres_restart")
      return true
    when "Failed", "NotStarted"
      vm.sshable.d_run("postgres_restart", "sudo", "postgres/bin/restart", postgres_server.version)
    end

    false
  end
end
