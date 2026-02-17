# frozen_string_literal: true

module PostgresTestHelpers
  def create_postgres_timeline(location_id:)
    t = PostgresTimeline.create(location_id:, access_key: "dummy-access-key", secret_key: "dummy-secret-key")
    Strand.create_with_id(t, prog: "Postgres::PostgresTimelineNexus", label: "start")
    t
  end

  def create_postgres_resource(project:, location_id:)
    pg = PostgresResource.create(
      location_id:,
      project:,
      name: "pg-test-#{SecureRandom.hex(4)}",
      target_vm_size: "standard-2",
      target_storage_size_gib: 64,
      target_version: PostgresResource::DEFAULT_VERSION,
      flavor: "standard",
      ha_type: "none",
      parent_id: nil,
      restore_target: nil,
      user_config: {},
      pgbouncer_user_config: {},
      superuser_password: "dummy-password",
      root_cert_1: "root_cert_1",
      root_cert_2: "root_cert_2",
      server_cert: "server_cert",
      server_cert_key: "server_cert_key"
    )
    Strand.create_with_id(pg, prog: "Postgres::PostgresResourceNexus", label: "start")
    pg
  end

  def create_postgres_server(
    resource:,
    timeline: create_postgres_timeline(location_id: resource.location_id),
    is_representative: true,
    timeline_access: is_representative ? "push" : "fetch"
  )
    vm = Prog::Vm::Nexus.assemble_with_sshable(resource.project_id, location_id: resource.location_id).subject
    VmStorageVolume.create(vm_id: vm.id, size_gib: resource.target_storage_size_gib, boot: false, disk_index: 1)

    ip_rand = SecureRandom.random_number(0xFFFFFF)
    AssignedVmAddress.create(dst_vm_id: vm.id, ip: "10.#{(ip_rand >> 16) & 0xFF}.#{(ip_rand >> 8) & 0xFF}.#{ip_rand & 0xFF}/32")
    vm.update(ephemeral_net6: "fd10:9b0b:6b4b:#{SecureRandom.hex(2)}::/79")

    s = PostgresServer.create(
      timeline:, resource:, vm_id: vm.id,
      is_representative:, synchronization_status: "ready",
      timeline_access:, version: PostgresResource::DEFAULT_VERSION
    )
    Strand.create_with_id(s, prog: "Postgres::PostgresServerNexus", label: "start")
    s
  end
end

RSpec.configure do |config|
  config.include PostgresTestHelpers
end
