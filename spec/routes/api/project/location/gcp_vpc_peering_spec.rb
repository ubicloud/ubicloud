# frozen_string_literal: true

require_relative "../../spec_helper"

RSpec.describe Clover, "GCP VPC peering" do
  let(:user) { create_account }
  let(:project) { project_with_default_policy(user) }
  let(:location) { Location[name: "gcp-us-central1"] }
  let(:ps) { Prog::Vnet::SubnetNexus.assemble(project.id, location_id: location.id).subject }
  let(:vpc) { Prog::Vnet::Gcp::VpcNexus.assemble(project.id, location.id, dedicated_for_subnet_id: ps.id).subject }
  let(:url) { "/project/#{project.ubid}/location/#{ps.display_location}/private-subnet/#{ps.ubid}/vpc-peering" }
  let(:params) { {peer_project_id: "customer-project", peer_network_name: "customer-vpc"} }

  before do
    login_api
    project.update(gcp_dedicated_subnet_vpcs: true)
    project.set_ff_vpc_peering_gcp(true)
    LocationCredentialGcp.create_with_id(location, project_id: "ubicloud-test", service_account_email: "test@ubicloud-test.iam.gserviceaccount.com", credentials_json: "{}")
    vpc.add_private_subnet(ps)
  end

  it "requires authentication" do
    header "Authorization", nil
    post url, params.to_json
    expect(last_response.status).to eq(401)
  end

  it "returns local setup information before a peer is configured" do
    get url
    expect(last_response.status).to eq(200)
    expect(JSON.parse(last_response.body)).to include("state" => "not_configured", "local_project_id" => "ubicloud-test", "local_network_name" => vpc.name)
  end

  it "configures one peer and wakes the VPC strand" do
    post url, params.to_json
    expect(last_response.status).to eq(200)
    expect(JSON.parse(last_response.body)).to include("peer_network" => "projects/customer-project/global/networks/customer-vpc", "state" => "creating")
    expect(vpc.reload.update_peering_set?).to be(true)
    expect(DB[:audit_log].where(project_id: project.id, action: "create_vpc_peering").count).to eq(1)
  end

  it "treats deleting an unconfigured peer as a successful no-op" do
    delete url
    expect(last_response.status).to eq(204)
    expect(vpc.reload.peer_network).to be_nil
    expect(vpc.update_peering_set?).to be(false)
  end

  it "rejects a second peer, including during removal" do
    vpc.configure_peering(**params)
    post url, params.merge(peer_network_name: "another-vpc").to_json
    expect(last_response.status).to eq(400)
    vpc.update(peering_state: "deleting")
    post url, params.to_json
    expect(last_response.status).to eq(400)
    expect(vpc.reload.peer_network).to end_with("/customer-vpc")
  end

  it "validates the customer project and network names" do
    post url, {peer_project_id: "../../bad", peer_network_name: "bad;command"}.to_json
    expect(last_response.status).to eq(400)
    expect(JSON.parse(last_response.body).dig("error", "details").keys).to contain_exactly("peer_project_id", "peer_network_name")
    expect(vpc.reload.peer_network).to be_nil
  end

  it "rejects a Ubicloud-managed peer network" do
    post url, params.merge(peer_project_id: "ubicloud-test", peer_network_name: vpc.name).to_json
    expect(last_response.status).to eq(400)
    expect(vpc.reload.peer_network).to be_nil
  end

  it "rejects a shared VPC even after the project enables dedicated VPCs" do
    vpc.update(dedicated_for_subnet_id: nil)
    post url, params.to_json
    expect(last_response.status).to eq(404)
  end

  it "rejects management VPCs" do
    vpc.update(is_management: true)
    post url, params.to_json
    expect(last_response.status).to eq(404)
  end

  it "requires the feature flag and dedicated-VPC project setting" do
    project.set_ff_vpc_peering_gcp(false)
    post url, params.to_json
    expect(last_response.status).to eq(404)
    project.set_ff_vpc_peering_gcp(true)
    project.update(gcp_dedicated_subnet_vpcs: false)
    post url, params.to_json
    expect(last_response.status).to eq(404)
  end

  it "refuses a subnet or VPC being destroyed" do
    [ps, vpc].each do |resource|
      resource.incr_destroy
      post url, params.to_json
      expect(last_response.status).to eq(400)
      resource.decr_destroy
    end
    expect(vpc.reload.peer_network).to be_nil
  end

  it "allows observing and disconnecting an existing peer after the feature flag is disabled" do
    vpc.configure_peering(**params)
    project.set_ff_vpc_peering_gcp(false)
    get url
    expect(last_response.status).to eq(200)
    delete url
    expect(last_response.status).to eq(204)
    expect(vpc.reload.peering_state).to eq("deleting")
    expect(vpc.update_peering_set?).to be(true)
    post url, params.to_json
    expect(last_response.status).to eq(400)
  end

  it "requires edit permission for both creation and deletion" do
    AccessControlEntry.dataset.destroy
    AccessControlEntry.create(project_id: project.id, subject_id: @pat.id, action_id: ActionType::NAME_MAP["PrivateSubnet:view"])
    AccessControlEntry.create(project_id: project.id, subject_id: user.id, action_id: ActionType::NAME_MAP["PrivateSubnet:view"])
    get url
    expect(last_response.status).to eq(200)
    post url, params.to_json
    expect(last_response.status).to eq(403)
    delete url
    expect(last_response.status).to eq(403)
  end

  describe "disconnecting during a status read" do
    v1 = Google::Cloud::Compute::V1

    let(:client) { instance_double(v1::Networks::Rest::Client) }
    let(:nx) {
      child = {"subject_id" => vpc.id, "link" => ["Vnet::Gcp::VpcNexus", "wait"]}
      st = vpc.strand.update(prog: "Vnet::Gcp::VpcPeering", label: "sync", stack: Sequel.pg_jsonb_wrap([child] + vpc.strand.stack))
      Prog::Vnet::Gcp::VpcPeering.new(st)
    }

    before do
      allow(Google::Auth::ServiceAccountCredentials).to receive(:make_creds)
      expect(v1::Networks::Rest::Client).to receive(:new).and_return(client)
      vpc.configure_peering(**params)
      vpc.update(peering_state: "waiting_for_peer")
    end

    it "removes the peer instead of overwriting an accepted disconnect with active status" do
      expect(client).to receive(:get) do
        delete url
        expect(last_response.status).to eq(204)
        v1::Network.new(peerings: [v1::NetworkPeering.new(name: vpc.peering_name, network: vpc.peer_network, state: "ACTIVE")])
      end
      expect(client).to receive(:remove_peering).with(
        project: "ubicloud-test", network: vpc.name,
        networks_remove_peering_request_resource: v1::NetworksRemovePeeringRequest.new(name: vpc.peering_name),
      ).and_return(v1::Operation.new(name: "delete-op"))
      expect { nx.sync }.to hop("wait_operation")
      expect(vpc.reload.peering_state).to eq("deleting")
    end

    it "preserves an accepted disconnect when the cloud read fails" do
      expect(client).to receive(:get) do
        delete url
        expect(last_response.status).to eq(204)
        raise Google::Cloud::InvalidArgumentError, "Peering request rejected"
      end
      expect { nx.sync }.to hop("sync")
      expect(vpc.reload.peering_state).to eq("deleting")
    end
  end

  it "does not expose another project's private subnet" do
    other = user.create_project_with_default_policy("other-project")
    get url.sub(project.ubid, other.ubid)
    expect(last_response.status).to eq(404)
  end
end
