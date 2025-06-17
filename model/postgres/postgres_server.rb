# frozen_string_literal: true

require "net/ssh"
require "uri"
require_relative "../../model"

class PostgresServer < Sequel::Model
  one_to_one :strand, key: :id
  many_to_one :resource, class: :PostgresResource, key: :resource_id
  many_to_one :timeline, class: :PostgresTimeline, key: :timeline_id
  one_to_one :vm, key: :id, primary_key: :vm_id
  one_to_one :lsn_monitor, class: :PostgresLsnMonitor, key: :postgres_server_id

  plugin :association_dependencies, lsn_monitor: :destroy

  plugin ResourceMethods
  include SemaphoreMethods
  include HealthMonitorMethods
  include MetricsTargetMethods

  semaphore :initial_provisioning, :refresh_certificates, :update_superuser_password, :checkup
  semaphore :restart, :configure, :take_over, :configure_metrics, :destroy, :recycle, :promote

  def configure_hash
    configs = {
      "listen_addresses" => "'*'",
      "max_connections" => "500",
      "superuser_reserved_connections" => "3",
      "shared_buffers" => "#{vm.memory_gib * 1024 / 4}MB",
      "work_mem" => "#{[vm.memory_gib / 8, 1].max}MB",
      "maintenance_work_mem" => "#{vm.memory_gib * 1024 / 16}MB",
      "max_parallel_workers" => "4",
      "max_parallel_workers_per_gather" => "2",
      "max_parallel_maintenance_workers" => "2",
      "min_wal_size" => "80MB",
      "max_wal_size" => "5GB",
      "random_page_cost" => "1.1",
      "effective_cache_size" => "#{vm.memory_gib * 1024 * 3 / 4}MB",
      "effective_io_concurrency" => "200",
      "tcp_keepalives_count" => "4",
      "tcp_keepalives_idle" => "2",
      "tcp_keepalives_interval" => "2",
      "ssl" => "on",
      "ssl_min_protocol_version" => "TLSv1.3",
      "ssl_ca_file" => "'/etc/ssl/certs/ca.crt'",
      "ssl_cert_file" => "'/etc/ssl/certs/server.crt'",
      "ssl_key_file" => "'/etc/ssl/certs/server.key'",
      "log_timezone" => "'UTC'",
      "log_directory" => "'pg_log'",
      "log_filename" => "'postgresql.log'",
      "log_truncate_on_rotation" => "true",
      "logging_collector" => "on",
      "timezone" => "'UTC'",
      "lc_messages" => "'C.UTF-8'",
      "lc_monetary" => "'C.UTF-8'",
      "lc_numeric" => "'C.UTF-8'",
      "lc_time" => "'C.UTF-8'",
      "shared_preload_libraries" => "'pg_cron,pg_stat_statements'"
    }

    if resource.flavor == PostgresResource::Flavor::PARADEDB
      configs["shared_preload_libraries"] = "'pg_cron,pg_stat_statements,pg_analytics,pg_search'"
    elsif resource.flavor == PostgresResource::Flavor::LANTERN
      configs["shared_preload_libraries"] = "'pg_cron,pg_stat_statements,lantern_extras'"
      configs["lantern.external_index_host"] = "'external-indexing.cloud.lantern.dev'"
      configs["lantern.external_index_port"] = "443"
      configs["lantern.external_index_secure"] = "true"
      configs["hnsw.external_index_host"] = "'external-indexing.cloud.lantern.dev'"
      configs["hnsw.external_index_port"] = "443"
      configs["hnsw.external_index_secure"] = "true"
    end

    if timeline.blob_storage
      if primary?
        configs[:archive_mode] = "on"
        configs[:archive_timeout] = "60"
        configs[:archive_command] = "'/usr/bin/wal-g wal-push %p --config /etc/postgresql/wal-g.env'"
        if resource.ha_type == PostgresResource::HaType::SYNC
          caught_up_standbys = resource.servers.select { it.standby? && it.synchronization_status == "ready" }
          configs[:synchronous_standby_names] = "'ANY 1 (#{caught_up_standbys.map(&:ubid).join(",")})'" unless caught_up_standbys.empty?
        end
      end

      if standby?
        configs[:primary_conninfo] = "'#{resource.replication_connection_string(application_name: ubid)}'"
      end

      if doing_pitr?
        configs[:recovery_target_time] = "'#{resource.restore_target}'"
      end

      if standby? || doing_pitr?
        configs[:restore_command] = "'/usr/bin/wal-g wal-fetch %f %p --config /etc/postgresql/wal-g.env'"
      end
    end

    {
      configs: configs,
      user_config: resource.user_config,
      pgbouncer_user_config: resource.pgbouncer_user_config,
      private_subnets: vm.private_subnets.map {
        {
          net4: it.net4.to_s,
          net6: it.net6.to_s
        }
      },
      identity: resource.identity,
      hosts: "#{resource.representative_server.vm.private_ipv4} #{resource.identity}",
      pgbouncer_instances: (vm.vcpus / 2.0).ceil.clamp(1, 8),
      metrics_config: metrics_config
    }
  end

  def trigger_failover
    if representative_at && (standby = failover_target)
      standby.incr_take_over
      true
    else
      Clog.emit("Failed to trigger failover")
      false
    end
  end

  def primary?
    timeline_access == "push"
  end

  def standby?
    timeline_access == "fetch" && !doing_pitr?
  end

  def doing_pitr?
    !resource.representative_server.primary?
  end

  def read_replica?
    resource.read_replica?
  end

  def storage_size_gib
    vm.vm_storage_volumes_dataset.first(boot: false)&.size_gib
  end

  def needs_recycling?
    recycle_set? || vm.display_size != resource.target_vm_size || storage_size_gib != resource.target_storage_size_gib
  end

  def lsn_caught_up
    parent_server = if read_replica?
      resource.parent.representative_server
    else
      resource.representative_server
    end
    lsn_diff(parent_server.current_lsn, current_lsn) < 80 * 1024 * 1024
  end

  def current_lsn
    run_query("SELECT #{lsn_function}").chomp
  end

  def failover_target
    target = resource.servers
      .reject { it.representative_at }
      .select { it.strand.label == "wait" && !it.needs_recycling? }
      .map { {server: it, lsn: it.current_lsn} }
      .max_by { lsn2int(it[:lsn]) }

    return nil if target.nil?

    if resource.ha_type == PostgresResource::HaType::ASYNC
      return nil if lsn_monitor.last_known_lsn.nil?
      return nil if lsn_diff(lsn_monitor.last_known_lsn, target[:lsn]) > 80 * 1024 * 1024 # 80 MB or ~5 WAL files
    end

    target[:server]
  end

  def lsn_function
    if primary?
      "pg_current_wal_lsn()"
    elsif standby?
      "pg_last_wal_receive_lsn()"
    else
      "pg_last_wal_replay_lsn()"
    end
  end

  def init_health_monitor_session
    FileUtils.rm_rf(health_monitor_socket_path)
    FileUtils.mkdir_p(health_monitor_socket_path)

    ssh_session = vm.sshable.start_fresh_session
    ssh_session.forward.local_socket(File.join(health_monitor_socket_path, ".s.PGSQL.5432"), "/var/run/postgresql/.s.PGSQL.5432")
    {
      ssh_session: ssh_session,
      db_connection: nil
    }
  end

  def init_metrics_export_session
    ssh_session = vm.sshable.start_fresh_session
    {
      ssh_session: ssh_session
    }
  end

  def check_pulse(session:, previous_pulse:)
    reading = begin
      session[:db_connection] ||= Sequel.connect(adapter: "postgres", host: health_monitor_socket_path, user: "postgres", connect_timeout: 4, keep_reference: false)
      last_known_lsn = session[:db_connection]["SELECT #{lsn_function} AS lsn"].first[:lsn]
      "up"
    rescue
      "down"
    end
    pulse = aggregate_readings(previous_pulse: previous_pulse, reading: reading, data: {last_known_lsn: last_known_lsn})

    DB.transaction do
      if pulse[:reading] == "up" && pulse[:reading_rpt] % 12 == 1
        begin
          PostgresLsnMonitor.new(last_known_lsn: last_known_lsn) { it.postgres_server_id = id }
            .insert_conflict(
              target: :postgres_server_id,
              update: {last_known_lsn: last_known_lsn}
            ).save_changes
        rescue Sequel::Error => ex
          Clog.emit("Failed to update PostgresLsnMonitor") { {lsn_update_error: {ubid: ubid, last_known_lsn: last_known_lsn, exception: Util.exception_to_hash(ex)}} }
        end
      end

      if pulse[:reading] == "down" && pulse[:reading_rpt] > 5 && Time.now - pulse[:reading_chg] > 30 && !reload.checkup_set?
        incr_checkup
      end
    end

    pulse
  end

  def needs_event_loop_for_pulse_check?
    true
  end

  def health_monitor_socket_path
    @health_monitor_socket_path ||= File.join(Dir.pwd, "var", "health_monitor_sockets", "pg_#{vm.ip6}")
  end

  def lsn2int(lsn)
    lsn.split("/").map { it.rjust(8, "0") }.join.hex
  end

  def lsn_diff(lsn1, lsn2)
    lsn2int(lsn1) - lsn2int(lsn2)
  end

  def self.run_query(vm, query)
    vm.sshable.cmd("PGOPTIONS='-c statement_timeout=60s' psql -U postgres -t --csv -v 'ON_ERROR_STOP=1'", stdin: query).chomp
  end

  def run_query(query)
    self.class.run_query(vm, query)
  end

  def metrics_config
    ignored_timeseries_patterns = [
      "pg_stat_user_tables_.*",
      "pg_statio_user_tables_.*"
    ]
    exclude_pattern = ignored_timeseries_patterns.join("|")
    query_params = {
      "match[]": "{__name__!~'#{exclude_pattern}'}"
    }
    query_str = URI.encode_www_form(query_params)

    {
      endpoints: [
        "https://localhost:9090/federate?#{query_str}"
      ],
      max_file_retention: 120,
      interval: "15s",
      additional_labels: {},
      metrics_dir: "/home/ubi/postgres/metrics",
      project_id: Config.postgres_service_project_id
    }
  end
end

# Table: postgres_server
# Columns:
#  id                     | uuid                     | PRIMARY KEY
#  created_at             | timestamp with time zone | NOT NULL DEFAULT now()
#  updated_at             | timestamp with time zone | NOT NULL DEFAULT now()
#  resource_id            | uuid                     | NOT NULL
#  vm_id                  | uuid                     |
#  timeline_id            | uuid                     | NOT NULL
#  timeline_access        | timeline_access          | NOT NULL DEFAULT 'push'::timeline_access
#  representative_at      | timestamp with time zone |
#  synchronization_status | synchronization_status   | NOT NULL DEFAULT 'ready'::synchronization_status
# Indexes:
#  postgres_server_pkey1             | PRIMARY KEY btree (id)
#  postgres_server_resource_id_index | UNIQUE btree (resource_id) WHERE representative_at IS NOT NULL
# Foreign key constraints:
#  postgres_server_timeline_id_fkey | (timeline_id) REFERENCES postgres_timeline(id)
#  postgres_server_vm_id_fkey       | (vm_id) REFERENCES vm(id)
