# frozen_string_literal: true

require "net/ssh"
require_relative "../../model"

class PostgresServer < Sequel::Model
  one_to_one :strand, key: :id
  many_to_one :resource, class: PostgresResource, key: :resource_id
  many_to_one :timeline, class: PostgresTimeline, key: :timeline_id
  one_to_one :vm, key: :id, primary_key: :vm_id
  one_to_one :lsn_monitor, class: PostgresLsnMonitor, key: :postgres_server_id

  plugin :association_dependencies, lsn_monitor: :destroy

  include ResourceMethods
  include SemaphoreMethods
  include HealthMonitorMethods

  semaphore :initial_provisioning, :refresh_certificates, :update_superuser_password, :checkup
  semaphore :restart, :configure, :update_firewall_rules, :take_over, :destroy

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
      ssl_ca_file: "'/dat/16/data/ca.crt'",
      ssl_cert_file: "'/dat/16/data/server.crt'",
      ssl_key_file: "'/dat/16/data/server.key'",
      log_timezone: "'UTC'",
      log_directory: "'pg_log'",
      log_filename: "'postgresql.log'",
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
        if resource.ha_type == PostgresResource::HaType::SYNC
          caught_up_standbys = resource.servers.select { _1.standby? && _1.synchronization_status == "ready" }
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
      private_subnets: vm.private_subnets.map {
        {
          net4: _1.net4.to_s,
          net6: _1.net6.to_s
        }
      },
      identity: resource.identity,
      hosts: "#{resource.representative_server.vm.ephemeral_net4} #{resource.identity}"
    }
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

  def failover_target
    target = resource.servers
      .select { _1.standby? && _1.strand.label == "wait" }
      .map { {server: _1, lsn: _1.run_query("SELECT pg_last_wal_receive_lsn()").chomp} }
      .max_by { lsn2int(_1[:lsn]) }

    return nil if target.nil?

    if resource.ha_type == PostgresResource::HaType::ASYNC
      return nil if lsn_monitor.last_known_lsn.nil?
      return nil if lsn_diff(lsn_monitor.last_known_lsn, target[:lsn]) > 80 * 1024 * 1024 # 80 MB or ~5 WAL files
    end

    target[:server]
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
    reading = begin
      session[:db_connection] ||= Sequel.connect(adapter: "postgres", host: health_monitor_socket_path, user: "postgres")
      lsn_function = primary? ? "pg_current_wal_lsn()" : "pg_last_wal_receive_lsn()"
      last_known_lsn = session[:db_connection]["SELECT #{lsn_function} AS lsn"].first[:lsn]
      "up"
    rescue
      "down"
    end
    pulse = aggregate_readings(previous_pulse: previous_pulse, reading: reading, data: {last_known_lsn: last_known_lsn})

    DB.transaction do
      if pulse[:reading] == "up" && pulse[:reading_rpt] % 12 == 1
        PostgresLsnMonitor.new(last_known_lsn: last_known_lsn) { _1.postgres_server_id = id }
          .insert_conflict(
            target: :postgres_server_id,
            update: {last_known_lsn: last_known_lsn}
          ).save_changes
      end

      if pulse[:reading] == "down" && pulse[:reading_rpt] > 5 && Time.now - pulse[:reading_chg] > 30 && !reload.checkup_set?
        incr_checkup
      end
    end

    pulse
  end

  def health_monitor_socket_path
    @health_monitor_socket_path ||= File.join(Dir.pwd, "var", "health_monitor_sockets", "pg_#{vm.ephemeral_net6.nth(2)}")
  end

  def create_resource_firewall_rules
    fw = Firewall.create_with_id(name: ubid.to_s, description: "Postgres default firewall")
    fw.add_private_subnet(vm.private_subnets.first)
    resource.firewall_rules.each do |pg_fwr|
      fw.insert_firewall_rule(pg_fwr.cidr.to_s, Sequel.pg_range(5432..5432))
    end
  end

  def lsn2int(lsn)
    lsn.split("/").map { _1.rjust(8, "0") }.join.hex
  end

  def lsn_diff(lsn1, lsn2)
    lsn2int(lsn1) - lsn2int(lsn2)
  end

  def run_query(query)
    vm.sshable.cmd("PGOPTIONS='-c statement_timeout=60s' psql -U postgres -t --csv", stdin: query).chomp
  end
end
