# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe PostgresGatewayReplica do
  it "reports whether it is serving" do
    gateway = PostgresGateway.create(location_id: Location::HETZNER_FSN1_ID, hostname_suffix: "ember.test")
    replica = described_class.create(postgres_gateway_id: gateway.id, vm_id: create_vm.id)
    expect(described_class.generate_ubid.to_s).to start_with("gk")
    expect(replica).not_to be_running
    replica.update(state: "running")
    expect(replica).to be_running
    expect(replica.postgres_gateway).to eq(gateway)
  end
end
