# frozen_string_literal: true

require "net/ssh"
require_relative "../../model"

class PostgresServer < Sequel::Model
  one_to_one :strand, key: :id
  many_to_one :resource, class: PostgresResource, key: :resource_id
  many_to_one :timeline, class: PostgresTimeline, key: :timeline_id
  one_to_one :vm, key: :id, primary_key: :vm_id

  include ResourceMethods
  include SemaphoreMethods
  include HealthMonitorMethods

  semaphore :initial_provisioning, :refresh_certificates, :update_superuser_password, :checkup, :destroy

  def configure_hash
    configs = {
      listen_addresses: "'*'",
      max_connections: (vm.mem_gib * 25).to_s,
      superuser_reserved_connections: "3",
      shared_buffers: "#{vm.mem_gib * 1024 / 4}MB",
      work_mem: "#{vm.mem_gib / 8}MB",
      maintenance_work_mem: "#{vm.mem_gib * 1024 / 16}MB",
      max_parallel_workers: "4",
      max_parallel_workers_per_gather: "2",
      max_parallel_maintenance_workers: "2",
      min_wal_size: "80MB",
      max_wal_size: "5GB",
      random_page_cost: "1.1",
      effective_cache_size: "#{vm.mem_gib * 1024 * 3 / 4}MB",
      effective_io_concurrency: "200",
      tcp_keepalives_count: "4",
      tcp_keepalives_idle: "2",
      tcp_keepalives_interval: "2",
      ssl: "on",
      ssl_min_protocol_version: "TLSv1.3",
      ssl_cert_file: "'/dat/16/data/server.crt'",
      ssl_key_file: "'/dat/16/data/server.key'",
      log_timezone: "'UTC'",
      log_directory: "'pg_log'",
      log_filename: "'postgresql-%A.log'",
      log_truncate_on_rotation: "true",
      logging_collector: "on",
      timezone: "'UTC'",
      lc_messages: "'C.UTF-8'",
      lc_monetary: "'C.UTF-8'",
      lc_numeric: "'C.UTF-8'",
      lc_time: "'C.UTF-8'"
    }

    if timeline.blob_storage
      if primary?
        configs[:archive_mode] = "on"
        configs[:archive_timeout] = "60"
        configs[:archive_command] = "'/usr/bin/wal-g wal-push %p --config /etc/postgresql/wal-g.env'"
      else
        configs[:recovery_target_time] = "'#{resource.restore_target}'"
        configs[:restore_command] = "'/usr/bin/wal-g wal-fetch %f %p --config /etc/postgresql/wal-g.env'"
      end
    end

    {
      configs: configs,
      private_subnets: vm.private_subnets.map {
        {
          net4: _1.net4.to_s,
          net6: _1.net6.to_s
        }
      }
    }
  end

  def primary?
    timeline_access == "push"
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

  def check_pulse(session:, previous_pulse:)
    session[:db_connection] ||= Sequel.connect(adapter: "postgres", host: health_monitor_socket_path, user: "postgres")

    reading = begin
      session[:db_connection]["SELECT 1"].all && "up"
    rescue
      "down"
    end
    pulse = aggregate_readings(previous_pulse: previous_pulse, reading: reading)

    if pulse[:reading] == "down" && pulse[:reading_rpt] > 5 && Time.now - pulse[:reading_chg] > 30
      incr_checkup
    end

    pulse
  end

  def health_monitor_socket_path
    @health_monitor_socket_path ||= File.join(Dir.pwd, "health_monitor_sockets", "pg_#{vm.ephemeral_net6.nth(2)}")
  end
end
