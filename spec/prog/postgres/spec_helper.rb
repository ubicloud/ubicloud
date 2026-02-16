# frozen_string_literal: true

require_relative "../../model/spec_helper"

RSpec.configure do |config|
  config.include(Module.new do
    def create_postgres_timeline
      tl_id = PostgresTimeline.generate_uuid
      tl = PostgresTimeline.create_with_id(tl_id,
        location_id:,
        access_key: "dummy-access-key",
        secret_key: "dummy-secret-key")
      Strand.create_with_id(tl_id, prog: "Postgres::PostgresTimelineNexus", label: "wait")
      tl
    end

    def create_postgres_resource(location_id:, target_version: "16")
      pr = PostgresResource.create(
        name: "pg-test-#{SecureRandom.hex(4)}",
        superuser_password: "dummy-password",
        ha_type: "none",
        target_version:,
        location_id:,
        project_id: project.id,
        user_config: {},
        pgbouncer_user_config: {},
        target_vm_size: "standard-2",
        target_storage_size_gib: 64,
        root_cert_1: "root_cert_1",
        root_cert_2: "root_cert_2",
        server_cert: "server_cert",
        server_cert_key: "server_cert_key"
      )
      Strand.create_with_id(pr, prog: "Postgres::PostgresResourceNexus", label: "wait")
      pr
    end

    def create_read_replica_resource(parent:, with_strand: false)
      pr = PostgresResource.create(
        name: "pg-replica-#{SecureRandom.hex(4)}",
        superuser_password: "dummy-password",
        ha_type: "none",
        target_version: "16",
        location_id:,
        project:,
        target_vm_size: "standard-2",
        target_storage_size_gib: 64,
        parent:
      )
      Strand.create_with_id(pr, prog: "Postgres::PostgresResourceNexus", label: "wait") if with_strand
      pr
    end

    def create_postgres_server(resource:, timeline: create_postgres_timeline, timeline_access: "push", is_representative: true, version: "16")
      vm = Prog::Vm::Nexus.assemble_with_sshable(
        project.id, name: "pg-vm-#{SecureRandom.hex(4)}", private_subnet_id: private_subnet.id,
        location_id:, unix_user: "ubi"
      ).subject
      VmStorageVolume.create(vm:, boot: false, size_gib: 64, disk_index: 1)
      server = PostgresServer.create(
        timeline:,
        resource:,
        vm_id: vm.id,
        is_representative:,
        synchronization_status: "ready",
        timeline_access:,
        version:
      )
      Strand.create_with_id(server, prog: "Postgres::PostgresServerNexus", label: "start")
      server
    end

    def create_standby_nexus(prime_sshable: false)
      server
      standby_record = create_postgres_server(
        resource: postgres_resource, timeline: postgres_timeline,
        is_representative: false, timeline_access: "fetch", version: "16"
      )
      standby_nx = described_class.new(standby_record.strand)
      ps = standby_nx.postgres_server
      resource = ps.resource
      rep = resource.representative_server
      if prime_sshable
        rep.vm.associations[:sshable] = rep.vm.sshable
        [standby_nx, rep.vm.sshable]
      else
        standby_nx
      end
    end
  end)
end
