# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe PostgresGateway do
  let(:gateway) {
    described_class.create(location_id: Location::HETZNER_FSN1_ID, hostname_suffix: "ember.test")
  }

  it "generates gw-prefixed ubids" do
    expect(described_class.generate_ubid.to_s).to start_with("gw")
  end

  it "builds an ember's hostname from its own suffix" do
    ember = create_postgres_ember
    expect(gateway.hostname_for(ember)).to eq("#{ember.ubid}.ember.test")
  end

  describe "#source_prefixes" do
    it "is empty with no replicas" do
      expect(gateway.source_prefixes).to eq([])
    end

    it "lists the guest half of each replica's block, which it speaks from inside the mesh" do
      vm = create_vm(vm_host_id: create_vm_host.id, ephemeral_net6: "2a01:4f8:10a:1:2::/79")
      EmberTunnel.ensure_keys(PostgresGatewayReplica.create(postgres_gateway_id: gateway.id, vm_id: vm.id))
      expect(gateway.reload.source_prefixes).to eq(["2a01:4f8:10a:1:2::/80"])
    end

    it "skips a replica that has not joined the mesh yet" do
      PostgresGatewayReplica.create(postgres_gateway_id: gateway.id, vm_id: create_vm.id)
      expect(gateway.reload.source_prefixes).to eq([])
    end
  end
end
