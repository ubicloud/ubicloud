# frozen_string_literal: true

require_relative "../../model"

class PostgresServer < Sequel::Model
  one_to_one :strand, key: :id
  many_to_one :resource, class: PostgresResource, key: :resource_id
  one_to_one :vm, key: :id, primary_key: :vm_id

  include ResourceMethods
  include SemaphoreMethods

  semaphore :initial_provisioning, :refresh_certificates, :destroy

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
      ssl_cert_file: "'/var/lib/postgresql/16/main/server.crt'",
      ssl_key_file: "'/var/lib/postgresql/16/main/server.key'",
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
end
