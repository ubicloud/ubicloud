# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe PostgresResource do
  subject(:pgs) {
    described_class.create_with_id(
      project_id: SecureRandom.uuid,
      location: "hetzner-hel1",
      server_name: "pg-server-name",
      target_vm_size: "standard-2",
      target_storage_size_gib: 100,
      superuser_password: "dummy-password"
    )
  }

  let(:vm) {
    instance_double(
      Vm,
      sshable: instance_double(Sshable, host: "1.2.3.4"),
      mem_gib: 8,
      private_subnets: [
        instance_double(
          PrivateSubnet,
          net4: NetAddr::IPv4Net.parse("172.0.0.0/26"),
          net6: NetAddr::IPv6Net.parse("fdfa:b5aa:14a3:4a3d::/64")
        )
      ]
    )
  }

  before do
    allow(pgs).to receive(:vm).and_return(vm)
  end

  it "generates configure_hash" do
    configure_hash = {
      configs: {
        effective_cache_size: "6144MB",
        effective_io_concurrency: 200,
        listen_addresses: "'*'",
        log_directory: "pg_log",
        log_filename: "'postgresql-%A.log'",
        log_truncate_on_rotation: "true",
        logging_collector: "on",
        maintenance_work_mem: "512MB",
        max_connections: 200,
        max_parallel_workers: 4,
        max_parallel_workers_per_gather: 2,
        max_parallel_maintenance_workers: 2,
        max_wal_size: "5GB",
        random_page_cost: 1.1,
        shared_buffers: "2048MB",
        superuser_reserved_connections: 3,
        tcp_keepalives_count: 4,
        tcp_keepalives_idle: 2,
        tcp_keepalives_interval: 2,
        work_mem: "1MB",
        ssl_cert_file: "'/var/lib/postgresql/16/main/server.crt'",
        ssl_key_file: "'/var/lib/postgresql/16/main/server.key'"
      },
      private_subnets: [
        {
          net4: "172.0.0.0/26",
          net6: "fdfa:b5aa:14a3:4a3d::/64"
        }
      ]
    }

    expect(pgs.configure_hash).to eq(configure_hash)
  end

  it "returns connection string" do
    expect(Config).to receive(:postgres_service_hostname).and_return("postgres.ubicloud.com")
    expect(pgs.connection_string).to eq("postgres://postgres:dummy-password@pg-server-name.postgres.ubicloud.com")
  end
end
