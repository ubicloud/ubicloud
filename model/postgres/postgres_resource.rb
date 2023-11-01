# frozen_string_literal: true

require_relative "../../model"

class PostgresResource < Sequel::Model
  one_to_one :strand, key: :id
  many_to_one :project
  many_to_one :vm
  one_to_many :active_billing_records, class: :BillingRecord, key: :resource_id do |ds| ds.active end

  include ResourceMethods
  include SemaphoreMethods
  include Authorization::HyperTagMethods
  include Authorization::TaggableMethods

  semaphore :initial_provisioning, :restart, :destroy

  plugin :column_encryption do |enc|
    enc.column :superuser_password
    enc.column :root_cert_key
    enc.column :server_cert_key
  end

  def hyper_tag_name(project)
    "project/#{project.ubid}/location/#{location}/postgres/#{server_name}"
  end

  def configure_hash
    {
      configs: {
        # TODO these are semi-arbitrary values. We should think more about them.
        effective_cache_size: "#{vm.mem_gib * 1024 * 3 / 4}MB",
        effective_io_concurrency: 200,
        listen_addresses: "'*'",
        log_directory: "pg_log",
        log_filename: "'postgresql-%A.log'",
        log_truncate_on_rotation: "true",
        logging_collector: "on",
        maintenance_work_mem: "#{vm.mem_gib * 1024 / 16}MB",
        max_connections: vm.mem_gib * 25,
        max_parallel_workers: 4,
        max_parallel_workers_per_gather: 2,
        max_parallel_maintenance_workers: 2,
        max_wal_size: "5GB",
        random_page_cost: 1.1,
        shared_buffers: "#{vm.mem_gib * 1024 / 4}MB",
        superuser_reserved_connections: 3,
        tcp_keepalives_count: 4,
        tcp_keepalives_idle: 2,
        tcp_keepalives_interval: 2,
        work_mem: "#{vm.mem_gib / 8}MB",
        ssl_cert_file: "'/var/lib/postgresql/16/main/server.crt'",
        ssl_key_file: "'/var/lib/postgresql/16/main/server.key'"
      },
      private_subnets: vm.private_subnets.map {
        {
          net4: _1.net4.to_s,
          net6: _1.net6.to_s
        }
      }
    }
  end

  def hostname
    "#{server_name}.#{Config.postgres_service_hostname}"
  end

  def connection_string
    URI::Generic.build2(scheme: "postgres", userinfo: "postgres:#{URI.encode_uri_component(superuser_password)}", host: hostname).to_s
  end
end
