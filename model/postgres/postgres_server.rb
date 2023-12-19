# frozen_string_literal: true

require_relative "../../model"

class PostgresServer < Sequel::Model
  one_to_one :strand, key: :id
  many_to_one :resource, class: PostgresResource, key: :resource_id
  many_to_one :timeline, class: PostgresTimeline, key: :timeline_id
  one_to_one :vm, key: :id, primary_key: :vm_id
  one_to_one :monitorable, key: :id

  include ResourceMethods
  include SemaphoreMethods

  semaphore :initial_provisioning, :refresh_certificates, :update_superuser_password, :destroy

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
    vm.sshable.connect
  end

  def check_health_status(session:)
    reading = begin
      (session.exec!("sudo -u postgres psql -At -c 'SELECT 1'").chomp == "1") ? "up" : "down"
    rescue
      "down"
    end

    status = {
      reading: reading,
      reading_rpt: (monitorable.status["reading"] == reading) ? monitorable.status["reading_rpt"] + 1 : 1,
      reading_chg: (monitorable.status["reading"] == reading) ? monitorable.status["reading_chg"] : Time.now
    }
    monitorable.update(status: status)

    if status["reading"] == "down" && status["reading_rpt"] > 5 && Time.now - Time.parse(status["reading_chg"]) > 30
      Prog::PageNexus.assemble("#{ubid} is unavailable!", [ubid], "PostgresServerUnavailable", id)
    end
  end
end
