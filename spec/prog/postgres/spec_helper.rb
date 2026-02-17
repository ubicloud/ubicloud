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

    def create_standby_nexus(prime_sshable: false)
      server
      standby_record = create_postgres_server(
        resource: postgres_resource, timeline: postgres_timeline,
        is_representative: false
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
