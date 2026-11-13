# frozen_string_literal: true

require "google/cloud/compute/v1"

RSpec.describe Prog::Vnet::Gcp::VpcPeeringNexus do
  v1 = Google::Cloud::Compute::V1

  subject(:nx) { described_class.new(st) }

  let(:project) { Project.create(name: "test-prj") }
  let(:location) { Location[name: "gcp-us-central1"] }
  let(:ps) {
    LocationCredentialGcp.create_with_id(location, project_id: "ubicloud-test", service_account_email: "test@ubicloud-test.iam.gserviceaccount.com", credentials_json: "{}")
    Prog::Vnet::SubnetNexus.assemble(project.id, name: "test-ps", location_id: location.id, ipv4_range: "10.10.0.0/26").subject.tap {
      Prog::Vnet::Gcp::VpcNexus.assemble(project.id, location.id, dedicated_for_subnet_id: it.id).subject.add_private_subnet(it)
    }
  }
  let(:network_name) { ps.gcp_vpc.name }
  let(:peer_path) { "projects/customer-project/global/networks/customer-vpc" }
  let(:st) { Prog::Vnet::VpcPeeringNexus.assemble(ps, peer_account_id: "customer-project", peer_vpc_id: peer_path) }
  let(:vp) { st.subject }
  let(:peering_name) { "ubicloud-#{vp.ubid}" }
  let(:networks) { instance_double(v1::Networks::Rest::Client) }
  let(:global_ops) { instance_double(v1::GlobalOperations::Rest::Client) }
  let(:add_slot) { {"name" => "op-add", "scope" => "global", "scope_value" => nil} }
  let(:remove_slot) { {"name" => "op-remove", "scope" => "global", "scope_value" => nil} }
  let(:overlap_hint) { "No subnet range of your network may overlap 10.10.0.0/26, or the subnets of networks peered with yours." }

  before do
    allow(v1::Networks::Rest::Client).to receive(:new).and_return(networks)
    allow(v1::GlobalOperations::Rest::Client).to receive(:new).and_return(global_ops)
    st
  end

  def half(name: peering_name, state: "ACTIVE", network: "https://www.googleapis.com/compute/v1/#{peer_path}", **)
    Google::Cloud::Compute::V1::NetworkPeering.new(name:, network:, state:, **)
  end

  def expect_read(*peerings)
    expect(networks).to receive(:get).with(project: "ubicloud-test", network: network_name).and_return(Google::Cloud::Compute::V1::Network.new(peerings:))
  end

  def expect_op(name, **)
    expect(global_ops).to receive(:get).with(project: "ubicloud-test", operation: name).and_return(Google::Cloud::Compute::V1::Operation.new(status: :DONE, **))
  end

  def route(dest_range, type: "SUBNET_PEERING_ROUTE", imported: true)
    Google::Cloud::Compute::V1::ExchangedPeeringRoute.new(dest_range:, type:, imported:)
  end

  def expect_routes(*routes)
    expect(networks).to receive(:list_peering_routes)
      .with(project: "ubicloud-test", network: network_name, peering_name:, direction: "INCOMING", region: "us-central1")
      .and_return(routes)
  end

  def deadline_at
    Time.new(frame_value(nx, "deadline_at"))
  end

  describe "#start" do
    it "naps while the private subnet is created, extending its deadline" do
      refresh_frame(nx, new_values: {"deadline_target" => "wait", "deadline_at" => st.time_string(Time.now + 60)})
      expect { nx.start }.to nap(10)
      expect(frame_value(nx, "deadline_target")).to eq "wait"
      expect(deadline_at).to be_within(5).of(Time.now + 15 * 60)
    end

    it "hops to add_peering once the private subnet waits" do
      ps.strand.update(label: "wait")
      expect { nx.start }.to hop("add_peering")
    end

    it "destroys itself when its private subnet is being destroyed" do
      ps.incr_destroying
      expect { nx.start }.to hop("destroy")
      expect(vp.reload.destroying_set?).to be true
    end

    it "commits its deadline before the first add, so an add that keeps raising pages" do
      ps.strand.update(label: "wait")
      expect(networks).to receive(:add_peering).twice.and_raise(Google::Cloud::UnauthenticatedError, "Request had invalid authentication credentials")
      expect { st.run(10) }.to raise_error(Strand::RunError)
      expect(st.reload.label).to eq "add_peering"
      expect(Time.new(st.stack.first["deadline_at"])).to be_within(5).of(Time.now + 15 * 60)
      refresh_frame(nx, new_values: {"deadline_at" => st.time_string(Time.now - 1)})
      expect { st.run(10) }.to raise_error(Strand::RunError).and change { Page.active.count }.from(0).to(1)
      expect(Page.active.get(:summary)).to include("Vnet::Gcp::VpcPeeringNexus.add_peering")
    end
  end

  describe "#add_peering" do
    it "adds our half exchanging only IPv4 subnet routes, records the global operation and logs the cleanup key" do
      expect(networks).to receive(:add_peering).with(
        project: "ubicloud-test",
        network: network_name,
        networks_add_peering_request_resource: v1::NetworksAddPeeringRequest.new(
          network_peering: v1::NetworkPeering.new(
            name: peering_name,
            network: peer_path,
            exchange_subnet_routes: true,
            stack_type: "IPV4_ONLY",
            import_custom_routes: false,
            export_custom_routes: false,
            import_subnet_routes_with_public_ip: false,
            export_subnet_routes_with_public_ip: false,
          ),
        ),
      ).and_return(v1::Operation.new(name: "op-add"))
      expect(Clog).to receive(:emit).with("GCP network peering created", {gcp_network_peering_created: "#{peering_name}@#{network_name}"}).and_call_original
      expect { nx.add_peering }.to hop("wait_add_peering")
      expect(frame_value(nx, "add_peering")).to eq add_slot
    end

    [
      [Google::Cloud::InvalidArgumentError, "There is a peering operation in progress on the local or peer network. Try again later."],
      [Google::Cloud::FailedPreconditionError, "The resource 'projects/customer-project/global/networks/customer-vpc' is not ready"],
      *described_class::TRANSIENT_ERRORS.map { [it, "Service unavailable"] },
    ].each do |error, message|
      it "retries #{error.name.split("::").last} saying #{message.inspect} without reading or failing" do
        expect(networks).to receive(:add_peering).and_raise(error, message)
        expect(networks).not_to receive(:get)
        expect { nx.add_peering }.to nap(15)
        expect(vp.reload.state).to eq "creating"
        expect(frame_value(nx, "add_peering")).to be_nil
      end
    end

    it "adopts our half from an earlier run whose add did not commit" do
      expect(networks).to receive(:add_peering).and_raise(Google::Cloud::AlreadyExistsError, "The resource already exists")
      expect_read(half(state: "INACTIVE"))
      expect { nx.add_peering }.to hop("wait_peering_created")
      expect(frame_value(nx, "add_peering")).to be_nil
    end

    it "raises when our half points to another network" do
      expect(networks).to receive(:add_peering).and_raise(Google::Cloud::AlreadyExistsError, "The resource already exists")
      expect_read(half(network: "https://www.googleapis.com/compute/v1/projects/other-project/global/networks/other"))
      expect { nx.add_peering }.to raise_error(RuntimeError, "GCP peering #{peering_name} on #{network_name} points to https://www.googleapis.com/compute/v1/projects/other-project/global/networks/other, not #{peer_path}")
    end

    it "naps while the read lags an AlreadyExists for our half" do
      expect(networks).to receive(:add_peering).and_raise(Google::Cloud::AlreadyExistsError, "The resource already exists")
      expect_read(half(name: "unrelated"))
      expect { nx.add_peering }.to nap(5)
      expect(vp.reload.state).to eq "creating"
    end

    it "naps while the read lags a refusal naming our half" do
      expect(networks).to receive(:add_peering).and_raise(Google::Cloud::InvalidArgumentError, "There is already a peering (#{peering_name}) with the same network")
      expect_read
      expect { nx.add_peering }.to nap(5)
      expect(vp.reload.state).to eq "creating"
    end

    it "raises when another peering of our network already targets the peer network" do
      expect(networks).to receive(:add_peering).and_raise(Google::Cloud::InvalidArgumentError, "There is already a peering (ubicloud-pxother) with the same network")
      expect_read(half(name: "ubicloud-pxother"))
      expect { nx.add_peering }.to raise_error(Google::Cloud::InvalidArgumentError, /already a peering \(ubicloud-pxother\)/)
      expect(vp.reload.state).to eq "creating"
    end

    [Google::Cloud::InvalidArgumentError, Google::Cloud::FailedPreconditionError, Google::Cloud::NotFoundError].each do |error|
      it "fails on #{error.name.split("::").last} as the customer's input, naming the ranges it must not overlap" do
        VpcPeering.create(private_subnet_id: ps.id, peer_account_id: "customer-project", peer_vpc_id: "projects/customer-project/global/networks/other-vpc", state: "active", peer_cidrs: Sequel.pg_array(["10.20.0.0/16", "10.21.0.0/24"], :cidr))
        expect(networks).to receive(:add_peering).and_raise(error, "Subnet ranges overlap")
        expect_read
        expect { nx.add_peering }.to hop("remove_peering")
        expect(vp.reload).to have_attributes(state: "failed", state_message: "GCP refused the peering with network customer-vpc in project customer-project. Check the project ID and network name. No subnet range of your network may overlap 10.10.0.0/26, the ranges of this subnet's other peerings (10.20.0.0/16, 10.21.0.0/24), or the subnets of networks peered with yours. Delete this peering and create it again. GCP said: Subnet ranges overlap")
        expect(frame_value(nx, "deadline_target")).to eq "failed"
        expect(deadline_at).to be_within(5).of(Time.now + 15 * 60)
      end
    end

    it "raises without failing when our own network is missing" do
      expect(networks).to receive(:add_peering).and_raise(Google::Cloud::NotFoundError, "The resource 'projects/ubicloud-test/global/networks/#{network_name}' was not found")
      expect(networks).to receive(:get).with(project: "ubicloud-test", network: network_name).and_raise(Google::Cloud::NotFoundError, "The resource 'projects/ubicloud-test/global/networks/#{network_name}' was not found")
      expect { nx.add_peering }.to raise_error(Google::Cloud::NotFoundError)
      expect(vp.reload.state).to eq "creating"
    end

    it "retries a permission refusal every 5 minutes with a notice, without failing" do
      message = "Required 'compute.networks.addPeering' permission for 'projects/ubicloud-test/global/networks/#{network_name}'"
      expect(networks).to receive(:add_peering).and_raise(Google::Cloud::PermissionDeniedError, message)
      expect(Clog).to receive(:emit).with("GCP refused to add a VPC peering, will retry", {gcp_vpc_peering_add_delayed: {ubid: vp.ubid, error: message}}).and_call_original
      expect { nx.add_peering }.to nap(5 * 60)
      expect(vp.reload).to have_attributes(state: "creating", state_message: "Ubicloud could not add its side of the peering yet and retries every 5 minutes. GCP said: #{message}")
    end
  end

  describe "#wait_add_peering" do
    before { refresh_frame(nx, new_values: {"add_peering" => add_slot}) }

    it "naps while the operation runs" do
      expect(global_ops).to receive(:get).with(project: "ubicloud-test", operation: "op-add").and_return(v1::Operation.new(status: :RUNNING))
      expect { nx.wait_add_peering }.to nap(5)
      expect(frame_value(nx, "add_peering")).to eq add_slot
    end

    it "clears the operation and hops to wait_peering_created once it is done" do
      expect_op("op-add")
      expect(networks).not_to receive(:get)
      expect { nx.wait_add_peering }.to hop("wait_peering_created")
      expect(frame_value(nx, "add_peering")).to be_nil
    end

    it "adopts our half when the operation failed but the half exists" do
      expect_op("op-add", error: {errors: [{code: "INTERNAL_ERROR", message: "Internal error"}]})
      expect_read(half(state: "INACTIVE"))
      expect(Clog).to receive(:emit).with("GCP LRO error but resource exists", {gcp_lro_recovered: {resource: "network peering #{peering_name}", error: "Internal error (code: INTERNAL_ERROR)"}}).and_call_original
      expect { nx.wait_add_peering }.to hop("wait_peering_created")
      expect(frame_value(nx, "add_peering")).to be_nil
    end

    it "raises when the operation failed and our half points to another network" do
      expect_op("op-add", error: {errors: [{code: "INTERNAL_ERROR", message: "Internal error"}]})
      expect_read(half(network: "https://www.googleapis.com/compute/v1/projects/other-project/global/networks/other"))
      expect { nx.wait_add_peering }.to raise_error(RuntimeError, /points to https:\/\/www.googleapis.com\/compute\/v1\/projects\/other-project\/global\/networks\/other/)
    end

    [
      {error: {errors: [{code: "RESOURCE_NOT_READY", message: "The resource is not ready"}]}},
      {error: {errors: [{code: "INVALID_USAGE", message: "There is a peering operation in progress on the local or peer network"}]}},
      {http_error_status_code: 503, http_error_message: "Service Unavailable"},
    ].each do |failure|
      it "clears the operation and adds again in 15 seconds after a transient failure #{failure}" do
        expect_op("op-add", **failure)
        expect_read
        expect { nx.wait_add_peering }.to hop("add_peering", nap: 15)
        expect(frame_value(nx, "add_peering")).to be_nil
        expect(vp.reload.state).to eq "creating"
      end
    end

    it "clears the operation and adds again in 5 minutes with a notice after a quota failure" do
      expect_op("op-add", error: {errors: [{code: "QUOTA_EXCEEDED", message: "Quota 'NETWORK_PEERINGS' exceeded"}]})
      expect_read
      expect(Clog).to receive(:emit).with("GCP refused to add a VPC peering, will retry", {gcp_vpc_peering_add_delayed: {ubid: vp.ubid, error: "Quota 'NETWORK_PEERINGS' exceeded (code: QUOTA_EXCEEDED)"}}).and_call_original
      expect { nx.wait_add_peering }.to hop("add_peering", nap: 5 * 60)
      expect(frame_value(nx, "add_peering")).to be_nil
      expect(vp.reload).to have_attributes(state: "creating", state_message: "Ubicloud could not add its side of the peering yet and retries every 5 minutes. GCP said: Quota 'NETWORK_PEERINGS' exceeded (code: QUOTA_EXCEEDED)")
    end

    it "fails the peering with GCP's message without polling the operation again" do
      expect_op("op-add", error: {errors: [{code: "INVALID_ARGUMENT", message: "Overlapping subnet ranges"}]})
      expect_read
      expect { nx.wait_add_peering }.to hop("remove_peering")
      expect(frame_value(nx, "add_peering")).to be_nil
      expect(vp.reload).to have_attributes(state: "failed", state_message: "GCP could not add Ubicloud's side of the peering with network customer-vpc in project customer-project. #{overlap_hint} Delete this peering and create it again. GCP said: Overlapping subnet ranges (code: INVALID_ARGUMENT)")
    end

    it "fails the peering on an operation that failed with only a 4xx status" do
      expect_op("op-add", http_error_status_code: 400, http_error_message: "Bad Request")
      expect_read
      expect { nx.wait_add_peering }.to hop("remove_peering")
      expect(vp.reload).to have_attributes(state: "failed", state_message: "GCP could not add Ubicloud's side of the peering with network customer-vpc in project customer-project. #{overlap_hint} Delete this peering and create it again. GCP said: Bad Request (HTTP 400)")
    end

    it "keeps the operation when a destroy arrives, so teardown drains it" do
      st.update(label: "wait_add_peering")
      vp.incr_destroy
      expect(st.run).to be_a(Prog::Base::Hop)
      expect(st.reload.label).to eq "destroy"
      expect(st.stack.first["add_peering"]).to eq add_slot
    end
  end

  describe "#wait_peering_created" do
    it "naps while our half is not visible yet" do
      expect_read
      expect { nx.wait_peering_created }.to nap(5)
    end

    it "raises when our half points to another network" do
      expect_read(half(network: "projects/other-project/global/networks/customer-vpc"))
      expect { nx.wait_peering_created }.to raise_error(RuntimeError, /points to projects\/other-project\/global\/networks\/customer-vpc/)
    end

    it "clears a delay notice and hops to wait" do
      vp.update(state_message: "Ubicloud could not add its side of the peering yet and retries every 5 minutes. GCP said: Quota exceeded")
      expect_read(half(state: "INACTIVE", network: peer_path))
      expect { nx.wait_peering_created }.to hop("wait")
      expect(vp.reload.state_message).to be_nil
    end

    it "hops to wait" do
      expect_read(half(state: "INACTIVE"))
      expect { nx.wait_peering_created }.to hop("wait")
      expect(vp.reload).to have_attributes(state: "creating", state_message: nil)
    end
  end

  describe "#wait" do
    let(:missing_message) { "Your side of the peering in project customer-project is missing or inactive, so traffic does not flow. Create it again with the command below, or delete this peering. GCP said: Peer network is not peered" }

    it "waits for the customer's half while ours is inactive, polling every minute in the first hour" do
      expect_read(half(state: "INACTIVE"))
      expect { nx.wait }.to nap(60)
      expect(vp.reload).to have_attributes(state: "waiting_for_peer", state_message: nil)
    end

    it "polls every 5 minutes after the first hour without writing" do
      vp.update(state: "waiting_for_peer", state_message: missing_message, created_at: Time.now - 2 * 60 * 60)
      expect_read(half(state: "INACTIVE"))
      expect { nx.wait }.to nap(5 * 60)
      expect(vp.reload).to have_attributes(state: "waiting_for_peer", state_message: missing_message)
    end

    it "marks a peering active straight from creating when the customer's half already exists" do
      expect_read(half)
      expect(networks).not_to receive(:list_peering_routes)
      expect { nx.wait }.to hop("refresh_peer_cidrs")
      expect(vp.reload).to have_attributes(state: "active", state_message: nil)
      expect(frame_value(nx, "deadline_target")).to eq "wait"
      expect(deadline_at).to be_within(5).of(Time.now + 15 * 60)
    end

    it "marks the peering active under a deadline and hops to refresh_peer_cidrs before reading routes" do
      vp.update(state: "waiting_for_peer", state_message: missing_message)
      expect_read(half)
      expect(networks).not_to receive(:list_peering_routes)
      expect { nx.wait }.to hop("refresh_peer_cidrs")
      expect(vp.reload).to have_attributes(state: "active", state_message: nil)
      expect(frame_value(nx, "deadline_target")).to eq "wait"
      expect(deadline_at).to be_within(5).of(Time.now + 15 * 60)
    end

    it "records the imported IPv4 subnet ranges of an active peering and polls every 15 minutes" do
      vp.update(state: "active")
      expect_read(half)
      expect_routes(
        route("10.21.0.0/24"),
        route("10.20.0.0/16"),
        route("10.21.0.0/24"),
        route("10.30.0.0/16", type: "STATIC_PEERING_ROUTE"),
        route("10.40.0.0/16", imported: false),
        route("fd20:1:2::/64"),
      )
      expect { nx.wait }.to nap(15 * 60)
      expect(vp.reload.peer_cidrs.map(&:to_s)).to eq ["10.20.0.0/16", "10.21.0.0/24"]
    end

    it "does not rewrite unchanged ranges" do
      vp.update(state: "active", peer_cidrs: Sequel.pg_array(["10.21.0.0/24", "10.20.0.0/16"], :cidr))
      expect_read(half)
      expect_routes(route("10.20.0.0/16"), route("10.21.0.0/24"))
      expect { nx.wait }.to nap(15 * 60)
      expect(vp.reload.peer_cidrs.map(&:to_s)).to eq ["10.21.0.0/24", "10.20.0.0/16"]
    end

    it "polls every minute in the first hour while an active peering shows no ranges" do
      vp.update(state: "active")
      expect_read(half)
      expect_routes
      expect { nx.wait }.to nap(60)
      expect(vp.reload.peer_cidrs).to eq []
    end

    it "returns to waiting_for_peer and clears the ranges when the customer's half goes inactive" do
      vp.update(state: "active", peer_cidrs: Sequel.pg_array(["10.20.0.0/16"], :cidr))
      expect_read(half(state: "INACTIVE", state_details: "Peer network is not peered"))
      expect(networks).not_to receive(:list_peering_routes)
      expect { nx.wait }.to nap(60)
      expect(vp.reload).to have_attributes(state: "waiting_for_peer", peer_cidrs: [], state_message: missing_message)
    end

    it "fails when our half no longer exists" do
      vp.update(state: "active")
      expect_read
      expect { nx.wait }.to hop("remove_peering")
      expect(vp.reload).to have_attributes(state: "failed", state_message: "Ubicloud's side of the peering (#{peering_name}) no longer exists in GCP, so traffic does not flow. Delete this peering and create it again.")
    end

    it "raises when our half points to another network" do
      vp.update(state: "active")
      expect_read(half(network: "https://www.googleapis.com/compute/v1/projects/other-project/global/networks/other"))
      expect(networks).not_to receive(:list_peering_routes)
      expect { nx.wait }.to raise_error(RuntimeError, /points to https:\/\/www.googleapis.com\/compute\/v1\/projects\/other-project\/global\/networks\/other/)
      expect(vp.reload.state).to eq "active"
    end
  end

  describe "#refresh_peer_cidrs" do
    it "records the ranges and hops to wait" do
      vp.update(state: "active")
      expect_routes(route("10.20.0.0/16"))
      expect { nx.refresh_peer_cidrs }.to hop("wait")
      expect(vp.reload.peer_cidrs.map(&:to_s)).to eq ["10.20.0.0/16"]
    end

    it "pages when the route read keeps raising, with the peering already active" do
      st.update(label: "wait")
      vp.update(state: "waiting_for_peer")
      expect_read(half)
      expect(networks).to receive(:list_peering_routes).twice.and_raise(Google::Cloud::PermissionDeniedError, "Required 'compute.networks.listPeeringRoutes' permission")
      expect { st.run(10) }.to raise_error(Strand::RunError)
      expect(st.reload.label).to eq "refresh_peer_cidrs"
      expect(vp.reload.state).to eq "active"
      refresh_frame(nx, new_values: {"deadline_at" => st.time_string(Time.now - 1)})
      expect { st.run(10) }.to raise_error(Strand::RunError).and change { Page.active.count }.from(0).to(1)
      expect(Page.active.get(:summary)).to include("Vnet::Gcp::VpcPeeringNexus.refresh_peer_cidrs")
    end
  end

  describe "#destroy" do
    it "is reached from wait by a destroy" do
      st.update(label: "wait")
      vp.incr_destroy
      expect(st.run).to be_a(Prog::Base::Hop)
      expect(st.reload.label).to eq "destroy"
      expect(vp.reload.destroying_set?).to be true
    end

    it "clears destroy, registers a deadline and hops to remove_peering" do
      vp.incr_destroy
      expect { nx.destroy }.to hop("remove_peering")
      expect(vp.reload.destroy_set?).to be false
      expect(nx.strand.stack.first).to include("deadline_target" => nil)
      expect(deadline_at).to be_within(5).of(Time.now + 15 * 60)
    end
  end

  describe "#remove_peering" do
    def expect_remove
      expect(networks).to receive(:remove_peering).with(
        project: "ubicloud-test",
        network: network_name,
        networks_remove_peering_request_resource: Google::Cloud::Compute::V1::NetworksRemovePeeringRequest.new(name: peering_name),
      )
    end

    it "removes our half by name without reading the network and records the operation" do
      expect(networks).not_to receive(:get)
      expect_remove.and_return(v1::Operation.new(name: "op-remove"))
      expect { nx.remove_peering }.to hop("wait_remove_peering")
      expect(frame_value(nx, "remove_peering")).to eq remove_slot
    end

    it "finishes a destroyed peering whose half is already gone, releasing its ranges" do
      vp.update(peer_cidrs: Sequel.pg_array(["10.20.0.0/16"], :cidr))
      vp.incr_destroying
      expect_remove.and_raise(Google::Cloud::NotFoundError, "The peering was not found")
      expect { nx.remove_peering }.to hop("finish")
      expect(vp.reload.peer_cidrs).to eq []
    end

    it "parks a failed peering whose half is already gone" do
      vp.update(state: "failed", state_message: "GCP refused the peering.")
      expect_remove.and_raise(Google::Cloud::NotFoundError, "The peering was not found")
      expect { nx.remove_peering }.to hop("failed")
    end

    it "finishes without any GCP call when the subnet no longer has a VPC network" do
      vp.incr_destroying
      DB[:private_subnet_gcp_vpc].where(private_subnet_id: ps.id).delete
      expect(networks).not_to receive(:remove_peering)
      expect { nx.remove_peering }.to hop("finish")
    end

    it "naps while a recorded add operation runs" do
      refresh_frame(nx, new_values: {"add_peering" => add_slot})
      expect(global_ops).to receive(:get).with(project: "ubicloud-test", operation: "op-add").and_return(v1::Operation.new(status: :RUNNING))
      expect(networks).not_to receive(:remove_peering)
      expect { nx.remove_peering }.to nap(5)
      expect(frame_value(nx, "add_peering")).to eq add_slot
    end

    it "drains a finished add operation, even a failed one, then removes" do
      refresh_frame(nx, new_values: {"add_peering" => add_slot})
      expect_op("op-add", error: {errors: [{code: "INVALID_ARGUMENT", message: "Overlapping subnet ranges"}]})
      expect_remove.and_return(v1::Operation.new(name: "op-remove"))
      expect { nx.remove_peering }.to hop("wait_remove_peering")
      expect(frame_value(nx, "add_peering")).to be_nil
      expect(frame_value(nx, "remove_peering")).to eq remove_slot
    end

    it "drains both recorded operations before removing" do
      refresh_frame(nx, new_values: {"add_peering" => add_slot, "remove_peering" => remove_slot})
      expect_op("op-add")
      expect_op("op-remove")
      expect_remove.and_return(v1::Operation.new(name: "op-remove-2"))
      expect { nx.remove_peering }.to hop("wait_remove_peering")
      expect(frame_value(nx, "add_peering")).to be_nil
      expect(frame_value(nx, "remove_peering")).to eq remove_slot.merge("name" => "op-remove-2")
    end

    [
      [Google::Cloud::InvalidArgumentError, "There is a peering operation in progress on the local or peer network. Try again later."],
      [Google::Cloud::FailedPreconditionError, "The resource 'projects/ubicloud-test/global/networks/x' is not ready"],
      [Google::Cloud::UnavailableError, "Service unavailable"],
    ].each do |error, message|
      it "retries #{error.name.split("::").last} saying #{message.inspect} in 15 seconds" do
        expect_remove.and_raise(error, message)
        expect(Clog).to receive(:emit).with("GCP refused to remove a VPC peering, will retry", {gcp_vpc_peering_remove_retry: {ubid: vp.ubid, error: message}}).and_call_original
        expect { nx.remove_peering }.to nap(15)
      end
    end

    it "parks a failed peering when GCP refuses to remove a half that was never added" do
      vp.update(state: "failed", state_message: "GCP refused the peering.")
      expect_remove.and_raise(Google::Cloud::InvalidArgumentError, "Invalid value for field 'name'")
      expect_read(half(name: "unrelated"))
      expect { nx.remove_peering }.to hop("failed")
    end

    it "finishes when GCP refuses the removal because our network is gone" do
      vp.incr_destroying
      expect_remove.and_raise(Google::Cloud::FailedPreconditionError, "The network is being deleted")
      expect(networks).to receive(:get).with(project: "ubicloud-test", network: network_name).and_raise(Google::Cloud::NotFoundError, "The resource 'projects/ubicloud-test/global/networks/#{network_name}' was not found")
      expect { nx.remove_peering }.to hop("finish")
    end

    [Google::Cloud::InvalidArgumentError, Google::Cloud::FailedPreconditionError].each do |error|
      it "raises #{error.name.split("::").last} when our half is still there" do
        expect_remove.and_raise(error, "Invalid value for field 'name'")
        expect_read(half)
        expect { nx.remove_peering }.to raise_error(error, "Invalid value for field 'name'")
      end
    end

    it "raises a permission refusal without reading" do
      expect_remove.and_raise(Google::Cloud::PermissionDeniedError, "Required 'compute.networks.removePeering' permission")
      expect(networks).not_to receive(:get)
      expect { nx.remove_peering }.to raise_error(Google::Cloud::PermissionDeniedError, "Required 'compute.networks.removePeering' permission")
    end
  end

  describe "#wait_remove_peering" do
    before { refresh_frame(nx, new_values: {"remove_peering" => remove_slot}) }

    it "naps while the operation runs" do
      expect(global_ops).to receive(:get).with(project: "ubicloud-test", operation: "op-remove").and_return(v1::Operation.new(status: :RUNNING))
      expect { nx.wait_remove_peering }.to nap(5)
    end

    it "clears a transiently failed operation and removes again in 15 seconds without reading" do
      expect_op("op-remove", http_error_status_code: 503)
      expect(networks).not_to receive(:get)
      expect(Clog).to receive(:emit).with("GCP VPC peering removal failed, will retry", {gcp_vpc_peering_remove_retry: {ubid: vp.ubid, error: "HTTP 503"}}).and_call_original
      expect { nx.wait_remove_peering }.to hop("remove_peering", nap: 15)
      expect(frame_value(nx, "remove_peering")).to be_nil
    end

    it "removes again in 15 seconds when the operation failed and our half is still there" do
      expect_op("op-remove", error: {errors: [{code: "INVALID_USAGE", message: "Peering cannot be removed"}]})
      expect_read(half)
      expect(Clog).to receive(:emit).with("GCP VPC peering removal failed, will retry", {gcp_vpc_peering_remove_retry: {ubid: vp.ubid, error: "Peering cannot be removed (code: INVALID_USAGE)"}}).and_call_original
      expect { nx.wait_remove_peering }.to hop("remove_peering", nap: 15)
      expect(frame_value(nx, "remove_peering")).to be_nil
    end

    it "finishes a destroyed peering when the operation failed on a half that is already gone" do
      nx.incr_destroying
      expect_op("op-remove", error: {errors: [{code: "RESOURCE_NOT_FOUND", message: "The peering does not exist"}]})
      expect_read
      expect(Clog).not_to receive(:emit)
      expect { nx.wait_remove_peering }.to hop("finish")
      expect(frame_value(nx, "remove_peering")).to be_nil
    end

    it "parks a failed peering without reading the network once the removal is done" do
      vp.update(state: "failed", state_message: "GCP refused the peering.", peer_cidrs: Sequel.pg_array(["10.20.0.0/16"], :cidr))
      expect_op("op-remove")
      expect(networks).not_to receive(:get)
      expect { nx.wait_remove_peering }.to hop("failed")
      expect(frame_value(nx, "remove_peering")).to be_nil
      expect(vp.reload.peer_cidrs).to eq []
    end
  end

  describe "#finish" do
    it "destroys the peering and its GCP row and pops" do
      expect { nx.finish }.to exit({"msg" => "vpc peering destroyed"})
      expect(VpcPeering[vp.id]).to be_nil
      expect(VpcPeeringGcpResource[vp.id]).to be_nil
    end
  end

  describe "#failed" do
    it "hibernates" do
      expect { nx.failed }.to hibernate
    end
  end

  describe "#before_run" do
    it "hops to destroy from the hibernating failed label" do
      st.update(label: "failed")
      vp.incr_destroy
      expect { nx.before_run }.to hop("destroy")
    end
  end

  it "parks a refused peering in failed, then a destroy deletes both rows, though GCP refuses each removal of the absent half" do
    st.update(label: "wait_add_peering")
    refresh_frame(nx, new_values: {"add_peering" => add_slot})
    expect_op("op-add", error: {errors: [{code: "INVALID_ARGUMENT", message: "Overlapping subnet ranges"}]})
    expect_read
    expect(networks).to receive(:remove_peering).and_return(v1::Operation.new(name: "op-remove"))
    expect_op("op-remove", error: {errors: [{code: "RESOURCE_NOT_FOUND", message: "The peering does not exist"}]})
    expect_read
    expect(st.run(10)).to be_a(Prog::Base::Nap)
    expect(st.reload.label).to eq "failed"
    expect(vp.reload.state).to eq "failed"

    vp.incr_destroy
    expect(networks).to receive(:remove_peering).and_raise(Google::Cloud::InvalidArgumentError, "Invalid value for field 'name'")
    expect_read
    expect(st.run(10)).to be_a(Prog::Base::Exit)
    expect(VpcPeering[vp.id]).to be_nil
    expect(VpcPeeringGcpResource[vp.id]).to be_nil
    expect(Strand[st.id]).to be_nil
  end
end
