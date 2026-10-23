# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Serializers::VpcPeering do
  describe ".serialize_internal" do
    let(:project) { Project.create(name: "test") }
    let(:ps) { PrivateSubnet.create(name: "test-ps", project_id: project.id, location_id: Location::HETZNER_FSN1_ID, net4: "10.9.0.0/16", net6: "fd1b:9793:dcef:cd0a::/64") }

    it "leaves out the provider block of a peering without a provider row" do
      vp = VpcPeering.create(private_subnet_id: ps.id, peer_account_id: "111122223333", peer_vpc_id: "vpc-0a1b2c3d4e5f60718")

      expect(described_class.serialize_internal(vp)).to eq(
        id: vp.ubid,
        state: "creating",
        state_message: nil,
        private_subnet_id: ps.ubid,
        location: "eu-central-h1",
        local_cidr: "10.9.0.0/16",
        peer_account_id: "111122223333",
        peer_vpc_id: "vpc-0a1b2c3d4e5f60718",
        peer_cidrs: [],
        created_at: vp.created_at.utc.iso8601,
      )
    end
  end
end
