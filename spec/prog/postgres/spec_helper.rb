# frozen_string_literal: true

require_relative "../../model/spec_helper"

RSpec.configure do |config|
  config.include(Module.new do
    def create_read_replica_resource(parent:)
      pr = create_postgres_resource(project:, location_id:)
      pr.update(parent_id: parent.id)
      pr.strand.update(label: "wait")
      pr
    end

    def create_postgres_server(resource:, timeline: create_postgres_timeline(location_id:), timeline_access: "push", is_representative: true, version: "16")
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
