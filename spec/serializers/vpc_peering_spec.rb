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

    it "adds the GCP block of a GCP peering" do
      location = Location[name: "gcp-us-central1"]
      LocationCredentialGcp.create_with_id(location, project_id: "ubicloud-test", service_account_email: "test@ubicloud-test.iam.gserviceaccount.com", credentials_json: "{}")
      ps.update(location_id: location.id)
      vpc = Prog::Vnet::Gcp::VpcNexus.assemble(project.id, location.id, dedicated_for_subnet_id: ps.id).subject
      vpc.add_private_subnet(ps)
      vp = VpcPeering.create(private_subnet_id: ps.id, peer_account_id: "customer-project", peer_vpc_id: "projects/customer-project/global/networks/customer-vpc")
      VpcPeeringGcpResource.create_with_id(vp, peering_name: "ubicloud-#{vp.ubid}")

      serialized = described_class.serialize_internal(vp)
      expect(serialized).to include(
        location: "us-central1",
        peer_account_id: "customer-project",
        peer_vpc_id: "projects/customer-project/global/networks/customer-vpc",
        gcp: {local_project_id: "ubicloud-test", local_network_name: vpc.name, peering_name: "ubicloud-#{vp.ubid}"},
      )
      expect(serialized).not_to have_key(:aws)
    end
  end
end
