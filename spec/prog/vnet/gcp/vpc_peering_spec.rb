# frozen_string_literal: true

require "google/cloud/compute/v1"

RSpec.describe Prog::Vnet::Gcp::VpcPeering do
  v1 = Google::Cloud::Compute::V1

  subject(:nx) { described_class.new(st) }

  let(:project) { Project.create(name: "peering-test") }
  let(:location) { Location[name: "gcp-us-central1"] }
  let(:ps) { Prog::Vnet::SubnetNexus.assemble(project.id, location_id: location.id).subject }
  let(:vpc) { Prog::Vnet::Gcp::VpcNexus.assemble(project.id, location.id, dedicated_for_subnet_id: ps.id).subject }
  let(:st) {
    child = {"subject_id" => vpc.id, "link" => ["Vnet::Gcp::VpcNexus", "wait"]}
    vpc.strand.update(prog: "Vnet::Gcp::VpcPeering", label: "sync", stack: Sequel.pg_jsonb_wrap([child] + vpc.strand.stack))
  }
  let(:client) { instance_double(v1::Networks::Rest::Client) }
  let(:ops) { instance_double(v1::GlobalOperations::Rest::Client) }
  let(:peering) { v1::NetworkPeering.new(name: vpc.peering_name, network: "https://www.googleapis.com/compute/v1/#{vpc.peer_network}", state: "ACTIVE") }

  before do
    LocationCredentialGcp.create_with_id(location, project_id: "ubicloud-test", service_account_email: "test@ubicloud-test.iam.gserviceaccount.com", credentials_json: "{}")
    allow(v1::Networks::Rest::Client).to receive(:new).and_return(client)
    allow(v1::GlobalOperations::Rest::Client).to receive(:new).and_return(ops)
    allow(Google::Auth::ServiceAccountCredentials).to receive(:make_creds)
    vpc.configure_peering(peer_project_id: "customer-project", peer_network_name: "customer-vpc")
  end

  def network_with(*peerings)
    Google::Cloud::Compute::V1::Network.new(peerings:)
  end

  describe "#sync" do
    it "creates only IPv4 subnet route exchange and records the global operation" do
      expect(client).to receive(:get).with(project: "ubicloud-test", network: vpc.name).and_return(network_with)
      expect(client).to receive(:add_peering) do |args|
        config = args[:networks_add_peering_request_resource].network_peering
        expect(config.name).to eq(vpc.peering_name)
        expect(config.network).to eq(vpc.peer_network)
        expect(config.stack_type).to eq("IPV4_ONLY")
        expect(config.exchange_subnet_routes).to be(true)
        expect([config.import_custom_routes, config.export_custom_routes, config.import_subnet_routes_with_public_ip, config.export_subnet_routes_with_public_ip]).to eq([false] * 4)
        v1::Operation.new(name: "add-op")
      end
      expect { nx.sync }.to hop("wait_operation")
      expect(st.stack.first.dig("peering_op", "name")).to eq("add-op")
    end

    it "recovers an uncommitted create by finding the deterministic peering name" do
      expect(client).to receive(:get).and_return(network_with(peering))
      expect(client).not_to receive(:add_peering)
      expect { nx.sync }.to hop("wait", "Vnet::Gcp::VpcNexus")
      expect(vpc.reload.peering_state).to eq("active")
    end

    it "reports an inactive peer without waiting on the VPC strand" do
      peering.state = "INACTIVE"
      peering.state_details = "Waiting for the peer network"
      expect(client).to receive(:get).and_return(network_with(peering))
      expect { nx.sync }.to hop("wait", "Vnet::Gcp::VpcNexus")
      expect(vpc.reload.peering_state).to eq("waiting_for_peer")
      expect(vpc.peering_state_message).to eq("Waiting for the peer network")
    end

    it "returns to waiting when the customer removes their side" do
      vpc.update(peering_state: "active")
      peering.state = "INACTIVE"
      expect(client).to receive(:get).and_return(network_with(peering))
      expect { nx.sync }.to hop("wait", "Vnet::Gcp::VpcNexus")
      expect(vpc.reload.peering_state).to eq("waiting_for_peer")
    end

    it "removes our configuration for either pending or active peerings" do
      vpc.update(peering_state: "deleting")
      expect(client).to receive(:get).and_return(network_with(peering))
      expect(client).to receive(:remove_peering).with(
        project: "ubicloud-test", network: vpc.name,
        networks_remove_peering_request_resource: v1::NetworksRemovePeeringRequest.new(name: vpc.peering_name),
      ).and_return(v1::Operation.new(name: "delete-op"))
      expect { nx.sync }.to hop("wait_operation")
    end

    it "removes peering when the VPC is being destroyed" do
      vpc.incr_destroying
      expect(client).to receive(:get).and_return(network_with(peering))
      expect(client).to receive(:remove_peering).and_return(v1::Operation.new(name: "delete-op"))
      expect { nx.sync }.to hop("wait_operation")
    end

    it "finishes an already completed deletion and preserves unrelated peerings" do
      vpc.update(peering_state: "deleting")
      other = v1::NetworkPeering.new(name: "unrelated")
      expect(client).to receive(:get).and_return(network_with(other))
      expect(client).not_to receive(:remove_peering)
      expect { nx.sync }.to hop("wait", "Vnet::Gcp::VpcNexus")
      expect(vpc.reload.values.values_at(:peer_network, :peering_state, :peering_state_message)).to eq([nil, nil, nil])
    end

    it "handles a VPC that was already deleted" do
      vpc.update(peering_state: "deleting")
      expect(client).to receive(:get).and_raise(Google::Cloud::NotFoundError)
      expect { nx.sync }.to hop("wait", "Vnet::Gcp::VpcNexus")
      expect(vpc.reload.peer_network).to be_nil
    end

    it "reports a missing local VPC during creation" do
      expect(client).to receive(:get).and_raise(Google::Cloud::NotFoundError.new("Network not found"))
      expect { nx.sync }.to hop("wait", "Vnet::Gcp::VpcNexus")
      expect(vpc.reload.peering_state).to eq("failed")
      expect(vpc.peering_state_message).to include("Network not found")
    end

    it "re-reads cloud state after an already-existing create response" do
      expect(client).to receive(:get).and_return(network_with)
      expect(client).to receive(:add_peering).and_raise(Google::Cloud::AlreadyExistsError)
      expect { nx.sync }.to nap(15)
      expect(client).to receive(:get).and_return(network_with(peering))
      expect { nx.sync }.to hop("wait", "Vnet::Gcp::VpcNexus")
      expect(vpc.reload.peering_state).to eq("active")
    end

    it "does not delete a same-named configuration pointing at a different network" do
      peering.network = "projects/other-project/global/networks/other"
      vpc.update(peering_state: "deleting")
      expect(client).to receive(:get).and_return(network_with(peering))
      expect { nx.sync }.to raise_error(/unexpected network/)
    end

    it "retries concurrent peering operations without marking the peer failed" do
      expect(client).to receive(:get).and_raise(Google::Cloud::InvalidArgumentError.new("There is a peering operation in progress"))
      expect { nx.sync }.to nap(15)
      expect(vpc.reload.peering_state).to eq("creating")
    end

    it "reports invalid input such as overlapping subnet ranges" do
      expect(client).to receive(:get).and_raise(Google::Cloud::InvalidArgumentError.new("Subnet ranges overlap"))
      expect { nx.sync }.to hop("wait", "Vnet::Gcp::VpcNexus")
      expect(vpc.reload.peering_state).to eq("failed")
      expect(vpc.peering_state_message).to include("Subnet ranges overlap")
    end
  end

  describe "#wait_operation" do
    before { refresh_frame(nx, new_values: {"peering_op" => {"name" => "op", "scope" => "global"}}) }

    it "waits for the operation" do
      expect(ops).to receive(:get).and_return(v1::Operation.new(status: :RUNNING))
      expect { nx.wait_operation }.to nap(5)
    end

    it "re-reads cloud state after completion" do
      expect(ops).to receive(:get).and_return(v1::Operation.new(status: :DONE))
      expect { nx.wait_operation }.to hop("sync")
      expect(st.stack.first).not_to have_key("peering_op")
    end

    it "records a failed create without polling the failed operation again" do
      op = v1::Operation.new(status: :DONE, error: {errors: [{code: "INVALID_ARGUMENT", message: "Overlapping subnet ranges"}]})
      expect(ops).to receive(:get).and_return(op)
      expect { nx.wait_operation }.to hop("wait", "Vnet::Gcp::VpcNexus")
      expect(vpc.reload.peering_state).to eq("failed")
      expect(st.stack.first).not_to have_key("peering_op")
    end

    it "drains an in-flight create before processing a delete request" do
      vpc.update(peering_state: "deleting")
      expect(ops).to receive(:get).and_return(v1::Operation.new(status: :DONE))
      expect { nx.wait_operation }.to hop("sync")
      expect(vpc.reload.peering_state).to eq("deleting")
    end

    it "does not let VPC destruction discard an in-flight operation's frame" do
      vpc.incr_destroy
      expect { nx.before_run }.not_to exit
      expect(ops).to receive(:get).and_return(v1::Operation.new(status: :RUNNING))
      expect { nx.wait_operation }.to nap(5)
      expect(st.stack.first).to have_key("peering_op")
    end

    it "clears a failed delete operation so it can be retried" do
      vpc.update(peering_state: "deleting")
      expect(ops).to receive(:get).and_return(v1::Operation.new(status: :DONE, http_error_status_code: 503))
      expect { nx.wait_operation }.to nap(15)
      expect(st.stack.first).not_to have_key("peering_op")
      expect { nx.wait_operation }.to hop("sync")
    end
  end
end
