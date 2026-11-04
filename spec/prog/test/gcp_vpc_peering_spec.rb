# frozen_string_literal: true

require "google/cloud/compute/v1"
require_relative "../../model/spec_helper"

RSpec.describe Prog::Test::GcpVpcPeering do
  v1 = Google::Cloud::Compute::V1

  subject(:vp_test) { described_class.new(st) }

  let(:st) { described_class.assemble }
  let(:service_project) { Project.create(name: "service-project") }
  let(:networks) { instance_double(v1::Networks::Rest::Client) }
  let(:subnetworks) { instance_double(v1::Subnetworks::Rest::Client) }
  let(:instances) { instance_double(v1::Instances::Rest::Client) }
  let(:global_ops) { instance_double(v1::GlobalOperations::Rest::Client) }
  let(:region_ops) { instance_double(v1::RegionOperations::Rest::Client) }
  let(:zone_ops) { instance_double(v1::ZoneOperations::Rest::Client) }
  let(:customer_name) { "vpc-peering-e2e-#{st.ubid}" }
  let(:customer_path) { "projects/e2e-project/global/networks/#{customer_name}" }
  let(:missing_name) { "#{customer_name}-missing" }
  let(:customer_cidr) { "192.168.240.0/24" }
  let(:private_subnet) { vp_test.private_subnet }
  let(:ubicloud_network) { "ubicloud-vpc-#{private_subnet.ubid}" }
  let(:vpc_peering) { VpcPeering[vp_test.vpc_peering_id] }
  let(:zone) { "us-central1-b" }
  let(:pg_ip) { vp_test.representative_server.vm.private_ipv4_string }
  let(:not_found) { Google::Cloud::NotFoundError }

  before do
    allow(Config).to receive(:postgres_service_project_id).and_return(service_project.id)
    allow(v1::Networks::Rest::Client).to receive(:new).and_return(networks)
    allow(v1::Subnetworks::Rest::Client).to receive(:new).and_return(subnetworks)
    allow(v1::Instances::Rest::Client).to receive(:new).and_return(instances)
    allow(v1::GlobalOperations::Rest::Client).to receive(:new).and_return(global_ops)
    allow(v1::RegionOperations::Rest::Client).to receive(:new).and_return(region_ops)
    allow(v1::ZoneOperations::Rest::Client).to receive(:new).and_return(zone_ops)
  end

  def start_test
    expect(Config).to receive(:e2e_gcp_credentials_base64_json)
      .and_return(Base64.strict_encode64({project_id: "e2e-project", client_email: "e2e@e2e-project.iam.gserviceaccount.com"}.to_json))
    expect { vp_test.start }.to hop("wait_postgres_resource")
  end

  def provision
    start_test
    vp_test.postgres_resource.strand.update(label: "wait")
    Prog::Vnet::Gcp::VpcNexus.assemble(private_subnet.project_id, private_subnet.location_id, dedicated_for_subnet_id: private_subnet.id).subject.add_private_subnet(private_subnet)
    az = LocationAz.create(location_id: vp_test.location_id, az: "b")
    VmGcpResource.create_with_id(vp_test.representative_server.vm, location_az_id: az.id)
  end

  def request_peering
    refresh_frame(vp_test, new_values: {"customer_cidr" => customer_cidr})
    expect { vp_test.request_peering }.to hop("wait_peering_requested")
  end

  def at_label(label, expired: false)
    st.update(label:)
    refresh_frame(vp_test, new_values: {"label_deadlines" => {label => Time.now.to_i - 1}}) if expired
  end

  def half(name, network, state: "ACTIVE")
    Google::Cloud::Compute::V1::NetworkPeering.new(name:, network: "https://www.googleapis.com/compute/v1/projects/e2e-project/global/networks/#{network}", state:)
  end

  def expect_network(name, *peerings)
    expect(networks).to receive(:get).with(project: "e2e-project", network: name).and_return(Google::Cloud::Compute::V1::Network.new(name:, peerings:))
  end

  def expect_network_missing(name)
    expect(networks).to receive(:get).with(project: "e2e-project", network: name).and_raise(not_found, "The resource 'projects/e2e-project/global/networks/#{name}' was not found")
  end

  def ubicloud_half(state: "ACTIVE")
    half("ubicloud-#{vpc_peering.ubid}", customer_name, state:)
  end

  def customer_half(state: "ACTIVE")
    half(customer_name, ubicloud_network, state:)
  end

  def op_failed(code, message)
    Google::Cloud::Compute::V1::Operation.new(status: :DONE, error: {errors: [{code:, message:}]})
  end

  def in_use(what)
    Google::Cloud::InvalidArgumentError.new("The #{what} resource '#{customer_path}' is already being used by 'projects/e2e-project/global/routes/peering-route-1'")
  end

  describe ".assemble" do
    it "creates a GCP test strand with its own project, which gives subnets their own VPC network" do
      expect { st }.to change { Project.select_order_map(:name) }.from(["service-project"]).to(["Gcp-Vpc-Peering-Test-Project", "service-project"])
      expect(st).to have_attributes(prog: "Test::GcpVpcPeering", label: "start")
      expect(st.stack.first).to include("provider" => "gcp", "gcp_location_name" => "gcp-us-central1")
      expect(Project[st.stack.first["postgres_test_project_id"]].gcp_dedicated_subnet_vpcs).to be true
    end
  end

  describe "#start" do
    it "creates a location in the test project with the E2E credential and a PostgreSQL resource in it" do
      start_test
      location = Location[vp_test.location_id]
      expect(location).to have_attributes(name: "gcp-us-central1", provider: "gcp", project_id: vp_test.postgres_test_project_id, byoc: false, display_name: customer_name, ui_name: customer_name)
      expect(Strand[location.id]).to have_attributes(prog: "LocationNexus", label: "wait")
      expect(location.location_credential_gcp).to have_attributes(project_id: "e2e-project", service_account_email: "e2e@e2e-project.iam.gserviceaccount.com")
      expect(vp_test.postgres_resource).to have_attributes(location_id: location.id, name: "postgres-test-vpc-peering", target_vm_size: "c4a-standard-4", target_storage_size_gib: 375)
      expect(vp_test.private_subnet_id).to eq vp_test.postgres_resource.private_subnet_id
    end

    it "fails the test without creating anything when a reused project does not give subnets their own VPC network" do
      vp_test.postgres_test_project.update(gcp_dedicated_subnet_vpcs: false)
      expect { vp_test.start }.to hop("failed")
        .and not_change(Location, :count)
      expect(st.reload.exitval).to eq("msg" => "Project #{vp_test.postgres_test_project.ubid} does not give its subnets their own VPC network, so they cannot be peered")
    end
  end

  describe "#wait_postgres_resource" do
    before { provision }

    let(:sshable) { vp_test.representative_server.vm.sshable }

    it "naps while the resource is not waiting" do
      vp_test.postgres_resource.strand.update(label: "start")
      expect { vp_test.wait_postgres_resource }.to nap(10)
    end

    it "naps while PostgreSQL does not answer" do
      expect(sshable).to receive(:_cmd).and_return("\n")
      expect { vp_test.wait_postgres_resource }.to nap(10)
    end

    it "hops to request_refused_peering once PostgreSQL answers" do
      expect(sshable).to receive(:_cmd).and_return("1\n")
      expect { vp_test.wait_postgres_resource }.to hop("request_refused_peering")
    end
  end

  describe "#request_refused_peering" do
    before { provision }

    it "requests a peering with a network that does not exist" do
      expect { vp_test.request_refused_peering }.to hop("wait_refused_peering")
      expect(vpc_peering).to have_attributes(private_subnet_id: private_subnet.id, peer_account_id: "e2e-project", peer_vpc_id: "projects/e2e-project/global/networks/#{missing_name}", state: "creating")
    end
  end

  describe "#wait_refused_peering" do
    before {
      provision
      expect { vp_test.request_refused_peering }.to hop("wait_refused_peering")
      at_label("wait_refused_peering")
    }

    let(:peering_strand) { Strand[vpc_peering.id] }

    it "destroys the peering once its teardown parked it in failed" do
      vpc_peering.update(state: "failed", state_message: "GCP refused the peering")
      peering_strand.update(label: "failed")
      expect { vp_test.wait_refused_peering }.to hop("wait_refused_peering_destroyed")
      expect(vpc_peering.destroy_set?(cached: false)).to be true
    end

    it "destroys the peering when GCP added our half anyway" do
      vpc_peering.update(state: "waiting_for_peer")
      expect { vp_test.wait_refused_peering }.to hop("wait_refused_peering_destroyed")
      expect(vpc_peering.destroy_set?(cached: false)).to be true
    end

    it "naps while the failed peering tears down" do
      vpc_peering.update(state: "failed", state_message: "GCP refused the peering")
      peering_strand.update(label: "remove_peering")
      expect { vp_test.wait_refused_peering }.to nap(5)
      expect(vpc_peering.destroy_set?(cached: false)).to be false
    end

    it "fails the test when the peering does not settle in time" do
      at_label("wait_refused_peering", expired: true)
      expect { vp_test.wait_refused_peering }.to hop("destroy")
      expect(vp_test.fail_message).to eq "VPC peering with a missing network did not settle within 5 minutes, it is creating in start"
    end
  end

  describe "#wait_refused_peering_destroyed" do
    before {
      provision
      expect { vp_test.request_refused_peering }.to hop("wait_refused_peering")
      at_label("wait_refused_peering_destroyed")
    }

    def finish_refused_peering
      peering_ubid = vpc_peering.ubid
      vpc_peering.destroy
      Strand[vp_test.vpc_peering_id].destroy
      at_label("wait_refused_peering_destroyed")
      peering_ubid
    end

    it "naps while the peering exists" do
      expect(networks).not_to receive(:get)
      expect { vp_test.wait_refused_peering_destroyed }.to nap(5)
    end

    it "fails the test when the peering is not destroyed in time" do
      at_label("wait_refused_peering_destroyed", expired: true)
      expect(networks).not_to receive(:get)
      expect { vp_test.wait_refused_peering_destroyed }.to hop("destroy")
      expect(vp_test.fail_message).to eq "VPC peering with a missing network was not destroyed within 10 minutes, it is creating in start"
    end

    it "fails the test when our half outlived the peering" do
      peering_ubid = finish_refused_peering
      expect_network(ubicloud_network, half("ubicloud-#{peering_ubid}", missing_name, state: "INACTIVE"))
      expect { vp_test.wait_refused_peering_destroyed }.to hop("destroy")
      expect(vp_test.fail_message).to eq "Ubicloud's side of the peering (ubicloud-#{peering_ubid}) is INACTIVE after the VPC peering with a missing network was destroyed"
    end

    it "forgets the peering and hops to create_customer_network once our half is gone" do
      finish_refused_peering
      expect_network(ubicloud_network, half("other", customer_name))
      expect { vp_test.wait_refused_peering_destroyed }.to hop("create_customer_network")
      expect(vp_test).to have_attributes(vpc_peering_id: nil, fail_message: nil)
    end
  end

  describe "#create_customer_network" do
    before { provision }

    it "creates a tagged custom-mode network and logs it for the CI cleanup" do
      expect(networks).to receive(:insert).with(
        project: "e2e-project",
        network_resource: v1::Network.new(
          name: customer_name,
          description: "VPC peering E2E customer network [Ubicloud=true]",
          auto_create_subnetworks: false,
          routing_config: v1::NetworkRoutingConfig.new(routing_mode: "REGIONAL"),
        ),
      ).and_return(v1::Operation.new(name: "op-network"))
      expect(Clog).to receive(:emit).with("GCP VPC created", {gcp_vpc_created: customer_name}).and_call_original
      expect { vp_test.create_customer_network }.to hop("wait_customer_network")
      expect(frame_value(vp_test, "create_network")).to eq("name" => "op-network", "scope" => "global", "scope_value" => nil)
    end

    it "adopts the network a previous attempt created" do
      expect(networks).to receive(:insert).and_raise(Google::Cloud::AlreadyExistsError, "The resource '#{customer_path}' already exists")
      expect(Clog).to receive(:emit).with("GCP VPC created", {gcp_vpc_created: customer_name}).and_call_original
      expect { vp_test.create_customer_network }.to hop("wait_customer_network")
      expect(frame_value(vp_test, "create_network")).to be_nil
    end
  end

  describe "#wait_customer_network" do
    before {
      provision
      at_label("wait_customer_network")
    }

    it "hops to create_customer_subnet once the network exists" do
      expect_network(customer_name)
      expect { vp_test.wait_customer_network }.to hop("create_customer_subnet")
    end

    describe "with the insert operation" do
      before { refresh_frame(vp_test, new_values: {"create_network" => {"name" => "op-network", "scope" => "global", "scope_value" => nil}}) }

      def expect_op
        expect(global_ops).to receive(:get).with(project: "e2e-project", operation: "op-network")
      end

      it "naps while the operation runs" do
        expect_op.and_return(v1::Operation.new(status: :RUNNING))
        expect(networks).not_to receive(:get)
        expect { vp_test.wait_customer_network }.to nap(5)
      end

      it "clears the operation once it is done and hops on when the network exists" do
        expect_op.and_return(v1::Operation.new(status: :DONE))
        expect_network(customer_name)
        expect { vp_test.wait_customer_network }.to hop("create_customer_subnet")
        expect(frame_value(vp_test, "create_network")).to be_nil
      end

      it "fails the test with GCP's error when the operation failed" do
        expect_op.and_return(op_failed("QUOTA_EXCEEDED", "Quota 'NETWORKS' exceeded."))
        expect(networks).not_to receive(:get)
        expect { vp_test.wait_customer_network }.to hop("destroy")
        expect(vp_test.fail_message).to eq "Customer network #{customer_name} could not be created: Quota 'NETWORKS' exceeded. (code: QUOTA_EXCEEDED)"
      end
    end

    it "naps while the network is created" do
      expect_network_missing(customer_name)
      expect { vp_test.wait_customer_network }.to nap(5)
      expect(vp_test.label_deadlines["wait_customer_network"]).to be_within(5).of(Time.now.to_i + 5 * 60)
    end

    it "fails the test when the network is not created in time" do
      at_label("wait_customer_network", expired: true)
      expect_network_missing(customer_name)
      expect { vp_test.wait_customer_network }.to hop("destroy")
      expect(vp_test.fail_message).to eq "Customer network #{customer_name} was not created within 5 minutes"
    end
  end

  describe "#create_customer_subnet" do
    before { provision }

    def expect_subnet_insert(cidr)
      expect(subnetworks).to receive(:insert).with(
        project: "e2e-project",
        region: "us-central1",
        subnetwork_resource: Google::Cloud::Compute::V1::Subnetwork.new(
          name: customer_name,
          description: "VPC peering E2E customer subnet [Ubicloud=true]",
          ip_cidr_range: cidr,
          network: customer_path,
          stack_type: "IPV4_ONLY",
        ),
      )
    end

    it "creates an IPv4 subnet in the region that does not overlap the database subnet and logs it for the CI cleanup" do
      expect_subnet_insert(customer_cidr).and_return(v1::Operation.new(name: "op-subnet"))
      expect(Clog).to receive(:emit).with("GCP subnet created", {gcp_subnet_created: "#{customer_name}@us-central1"}).and_call_original
      expect { vp_test.create_customer_subnet }.to hop("wait_customer_subnet")
      expect(vp_test.customer_cidr).to eq customer_cidr
      expect(frame_value(vp_test, "create_subnet")).to eq("name" => "op-subnet", "scope" => "region", "scope_value" => "us-central1")
    end

    it "uses another range when the database subnet is in the first one" do
      private_subnet.update(net4: "192.168.240.64/26")
      expect_subnet_insert("10.255.240.0/24").and_return(v1::Operation.new(name: "op-subnet"))
      expect { vp_test.create_customer_subnet }.to hop("wait_customer_subnet")
      expect(vp_test.customer_cidr).to eq "10.255.240.0/24"
    end

    it "adopts the subnet a previous attempt created" do
      expect_subnet_insert(customer_cidr).and_raise(Google::Cloud::AlreadyExistsError, "The resource already exists")
      expect(Clog).to receive(:emit).with("GCP subnet created", {gcp_subnet_created: "#{customer_name}@us-central1"}).and_call_original
      expect { vp_test.create_customer_subnet }.to hop("wait_customer_subnet")
    end

    it "naps while the network is not ready" do
      expect_subnet_insert(customer_cidr).and_raise(Google::Cloud::InvalidArgumentError, "The resource '#{customer_path}' is not ready")
      expect(Clog).not_to receive(:emit)
      expect { vp_test.create_customer_subnet }.to nap(5)
      expect(vp_test.customer_cidr).to eq customer_cidr
    end

    it "raises other refusals" do
      expect_subnet_insert(customer_cidr).and_raise(Google::Cloud::InvalidArgumentError, "Invalid value for field 'resource.ipCidrRange'")
      expect { vp_test.create_customer_subnet }.to raise_error(Google::Cloud::InvalidArgumentError, "Invalid value for field 'resource.ipCidrRange'")
    end
  end

  describe "#wait_customer_subnet" do
    before {
      provision
      at_label("wait_customer_subnet")
    }

    it "hops to request_peering once the subnet exists" do
      expect(subnetworks).to receive(:get).with(project: "e2e-project", region: "us-central1", subnetwork: customer_name).and_return(v1::Subnetwork.new(name: customer_name))
      expect { vp_test.wait_customer_subnet }.to hop("request_peering")
    end

    it "fails the test with GCP's error when the insert operation failed" do
      refresh_frame(vp_test, new_values: {"create_subnet" => {"name" => "op-subnet", "scope" => "region", "scope_value" => "us-central1"}})
      expect(region_ops).to receive(:get).with(project: "e2e-project", region: "us-central1", operation: "op-subnet").and_return(op_failed("QUOTA_EXCEEDED", "Quota 'SUBNETWORKS' exceeded."))
      expect(subnetworks).not_to receive(:get)
      expect { vp_test.wait_customer_subnet }.to hop("destroy")
      expect(vp_test.fail_message).to eq "Customer subnet #{customer_name} could not be created: Quota 'SUBNETWORKS' exceeded. (code: QUOTA_EXCEEDED)"
    end

    it "naps while the subnet is created" do
      expect(subnetworks).to receive(:get).and_raise(not_found, "not found")
      expect { vp_test.wait_customer_subnet }.to nap(5)
    end

    it "fails the test when the subnet is not created in time" do
      at_label("wait_customer_subnet", expired: true)
      expect(subnetworks).to receive(:get).and_raise(not_found, "not found")
      expect { vp_test.wait_customer_subnet }.to hop("destroy")
      expect(vp_test.fail_message).to eq "Customer subnet #{customer_name} was not created within 5 minutes"
    end
  end

  describe "#request_peering" do
    before { provision }

    it "requests a peering of the database subnet with the customer network" do
      request_peering
      expect(vpc_peering).to have_attributes(private_subnet_id: private_subnet.id, peer_account_id: "e2e-project", peer_vpc_id: customer_path, state: "creating")
      expect(vpc_peering.vpc_peering_gcp_resource.peering_name).to eq "ubicloud-#{vpc_peering.ubid}"
      expect(Strand[vpc_peering.id]).to have_attributes(prog: "Vnet::Gcp::VpcPeeringNexus", label: "start")
    end

    it "waits for the second peering to become active, since the customer side is still in place" do
      refresh_frame(vp_test, new_values: {"cascade_peering" => true})
      expect { vp_test.request_peering }.to hop("wait_peering_active")
      expect(vpc_peering.peer_vpc_id).to eq customer_path
    end
  end

  describe "#wait_peering_requested" do
    before {
      provision
      request_peering
      at_label("wait_peering_requested")
    }

    it "hops to add_customer_peering once our side waits for the customer" do
      vpc_peering.update(state: "waiting_for_peer")
      expect { vp_test.wait_peering_requested }.to hop("add_customer_peering")
    end

    it "fails the test when the peering fails" do
      vpc_peering.update(state: "failed", state_message: "GCP refused the peering")
      expect { vp_test.wait_peering_requested }.to hop("destroy")
      expect(vp_test.fail_message).to eq "VPC peering failed: GCP refused the peering"
    end

    it "naps while our side is added" do
      expect { vp_test.wait_peering_requested }.to nap(5)
      expect(vp_test.label_deadlines["wait_peering_requested"]).to be_within(5).of(Time.now.to_i + 5 * 60)
      expect(vp_test.fail_message).to be_nil
    end

    it "fails the test when our side is not added in time" do
      at_label("wait_peering_requested", expired: true)
      expect { vp_test.wait_peering_requested }.to hop("destroy")
      expect(vp_test.fail_message).to eq "Ubicloud's side of the VPC peering was not added within 5 minutes, state creating"
    end

    it "names GCP's refusal when our side is not added in time" do
      at_label("wait_peering_requested", expired: true)
      vpc_peering.update(state_message: "Ubicloud could not add its side of the peering yet and retries every 5 minutes. GCP said: Required 'compute.networks.addPeering' permission")
      expect { vp_test.wait_peering_requested }.to hop("destroy")
      expect(vp_test.fail_message).to eq "Ubicloud's side of the VPC peering was not added within 5 minutes, state creating: Ubicloud could not add its side of the peering yet and retries every 5 minutes. GCP said: Required 'compute.networks.addPeering' permission"
    end
  end

  describe "#add_customer_peering" do
    before {
      provision
      request_peering
    }

    let(:add_request) {
      {
        project: "e2e-project",
        network: customer_name,
        networks_add_peering_request_resource: v1::NetworksAddPeeringRequest.new(
          network_peering: v1::NetworkPeering.new(
            name: customer_name,
            network: "projects/e2e-project/global/networks/#{ubicloud_network}",
            exchange_subnet_routes: true,
            stack_type: "IPV4_ONLY",
            import_custom_routes: false,
            export_custom_routes: false,
            import_subnet_routes_with_public_ip: false,
            export_subnet_routes_with_public_ip: false,
          ),
        ),
      }
    }

    it "adds the customer side toward the Ubicloud network and logs it for the CI cleanup" do
      expect_network(customer_name)
      expect(networks).to receive(:add_peering).with(add_request).and_return(v1::Operation.new(name: "op-add"))
      expect(Clog).to receive(:emit).with("GCP network peering created", {gcp_network_peering_created: "#{customer_name}@#{customer_name}"}).and_call_original
      expect { vp_test.add_customer_peering }.to hop("wait_peering_active")
    end

    it "adopts the customer side a previous attempt added" do
      expect_network(customer_name, customer_half(state: "INACTIVE"))
      expect(networks).not_to receive(:add_peering)
      expect(Clog).to receive(:emit).with("GCP network peering created", {gcp_network_peering_created: "#{customer_name}@#{customer_name}"}).and_call_original
      expect { vp_test.add_customer_peering }.to hop("wait_peering_active")
    end

    it "naps while another peering operation runs" do
      expect_network(customer_name)
      expect(networks).to receive(:add_peering).with(add_request).and_raise(Google::Cloud::InvalidArgumentError, "There is a peering operation in progress on the local or peer network. Try again later.")
      expect { vp_test.add_customer_peering }.to nap(15)
    end

    it "raises other refusals" do
      expect_network(customer_name)
      expect(networks).to receive(:add_peering).and_raise(Google::Cloud::FailedPreconditionError, "Peering is not allowed by an organization policy")
      expect { vp_test.add_customer_peering }.to raise_error(Google::Cloud::FailedPreconditionError, "Peering is not allowed by an organization policy")
    end
  end

  describe "#wait_peering_active" do
    before {
      provision
      request_peering
      at_label("wait_peering_active")
    }

    let(:peering_strand) { Strand[vpc_peering.id] }

    def activate(cidrs: [customer_cidr])
      vpc_peering.update(state: "active", peer_cidrs: Sequel.pg_array(cidrs, :cidr))
      peering_strand.update(label: "wait", schedule: Time.now + 15 * 60)
    end

    it "hops to launch_client once our side is active and imports the customer subnet" do
      activate
      expect_network(ubicloud_network, ubicloud_half)
      expect { vp_test.wait_peering_active }.to hop("launch_client")
      expect(vp_test.fail_message).to be_nil
    end

    it "hops to destroy_peered_postgres once the cascade peering is active" do
      refresh_frame(vp_test, new_values: {"cascade_peering" => true})
      activate
      expect_network(ubicloud_network, ubicloud_half)
      expect { vp_test.wait_peering_active }.to hop("destroy_peered_postgres")
      expect(vp_test.fail_message).to be_nil
    end

    it "naps while our side is not active yet" do
      activate
      expect_network(ubicloud_network, ubicloud_half(state: "INACTIVE"))
      expect { vp_test.wait_peering_active }.to nap(5)
      expect(vp_test.label_deadlines["wait_peering_active"]).to be_within(5).of(Time.now.to_i + 5 * 60)
      expect(vp_test.fail_message).to be_nil
    end

    describe "once the deadline passed" do
      before { at_label("wait_peering_active", expired: true) }

      it "fails the test when the peering imported other ranges" do
        activate(cidrs: [])
        expect(networks).not_to receive(:get)
        expect { vp_test.wait_peering_active }.to hop("destroy")
        expect(vp_test.fail_message).to eq "VPC peering routes [], expected [#{customer_cidr}]"
      end

      it "fails the test when our side is gone" do
        activate
        expect_network(ubicloud_network, half("other", "other-network"))
        expect { vp_test.wait_peering_active }.to hop("destroy")
        expect(vp_test.fail_message).to eq "Ubicloud's side of the peering is missing, expected ACTIVE"
      end

      it "fails the test when our side is not active" do
        activate
        expect_network(ubicloud_network, ubicloud_half(state: "INACTIVE"))
        expect { vp_test.wait_peering_active }.to hop("destroy")
        expect(vp_test.fail_message).to eq "Ubicloud's side of the peering is INACTIVE, expected ACTIVE"
      end

      describe "with our side active" do
        before do
          activate
          expect_network(ubicloud_network, ubicloud_half)
        end

        it "fails the test when the peering is not in wait" do
          peering_strand.update(label: "refresh_peer_cidrs")
          expect { vp_test.wait_peering_active }.to hop("destroy")
          expect(vp_test.fail_message).to eq "VPC peering has not settled in wait, it is in refresh_peer_cidrs (try 0)"
        end

        it "fails the test when the peering keeps failing in wait" do
          peering_strand.update(try: 9)
          expect { vp_test.wait_peering_active }.to hop("destroy")
          expect(vp_test.fail_message).to eq "VPC peering has not settled in wait, it is in wait (try 9)"
        end

        it "fails the test when wait did not take its long nap" do
          peering_strand.update(schedule: Time.now + 60)
          expect { vp_test.wait_peering_active }.to hop("destroy")
          expect(vp_test.fail_message).to eq "VPC peering has not settled in wait, it is in wait (try 0)"
        end

        it "fails the test when the peering shows warnings" do
          vpc_peering.update(state_message: "Your side of the peering is missing")
          expect { vp_test.wait_peering_active }.to hop("destroy")
          expect(vp_test.fail_message).to eq "VPC peering is active with warnings: Your side of the peering is missing"
        end
      end
    end

    it "fails the test when the peering fails" do
      vpc_peering.update(state: "failed", state_message: "GCP refused the peering")
      expect { vp_test.wait_peering_active }.to hop("destroy")
      expect(vp_test.fail_message).to eq "VPC peering failed: GCP refused the peering"
    end

    it "naps while the peering waits for the customer side" do
      vpc_peering.update(state: "waiting_for_peer")
      expect { vp_test.wait_peering_active }.to nap(5)
    end

    it "fails the test when the peering does not become active in time" do
      vpc_peering.update(state: "waiting_for_peer")
      at_label("wait_peering_active", expired: true)
      expect { vp_test.wait_peering_active }.to hop("destroy")
      expect(vp_test.fail_message).to eq "VPC peering did not become active within 5 minutes, state waiting_for_peer"
    end

    it "names the peering's notice when it does not become active in time" do
      vpc_peering.update(state: "waiting_for_peer", state_message: "Your side of the peering in project e2e-project is missing or inactive")
      at_label("wait_peering_active", expired: true)
      expect { vp_test.wait_peering_active }.to hop("destroy")
      expect(vp_test.fail_message).to eq "VPC peering did not become active within 5 minutes, state waiting_for_peer: Your side of the peering in project e2e-project is missing or inactive"
    end
  end

  describe "#launch_client" do
    before {
      provision
      refresh_frame(vp_test, new_values: {"customer_cidr" => customer_cidr})
    }

    let(:startup_script) {
      <<~SH
        #!/bin/bash
        shutdown -h +60
        tcp=fail
        for i in $(seq 30); do
          timeout 5 bash -c "exec 3<>/dev/tcp/#{pg_ip}/5432" && tcp=ok && break
          sleep 10
        done
        echo "ubie2e result tcp=$tcp" >/dev/ttyS0
      SH
    }

    let(:instance) {
      v1::Instance.new(
        name: customer_name,
        machine_type: "zones/#{zone}/machineTypes/e2-micro",
        labels: {"ubicloud" => "true"},
        disks: [
          v1::AttachedDisk.new(
            auto_delete: true,
            boot: true,
            initialize_params: v1::AttachedDiskInitializeParams.new(source_image: "projects/ubuntu-os-cloud/global/images/family/ubuntu-2404-lts-amd64"),
          ),
        ],
        network_interfaces: [
          v1::NetworkInterface.new(
            network: customer_path,
            subnetwork: "projects/e2e-project/regions/us-central1/subnetworks/#{customer_name}",
            stack_type: "IPV4_ONLY",
          ),
        ],
        metadata: v1::Metadata.new(items: [v1::Items.new(key: "startup-script", value: startup_script)]),
      )
    }

    it "launches a client without a public address in the database zone, probing the database private address" do
      expect(private_subnet.net4.contains(NetAddr::IPv4.parse(pg_ip))).to be true
      expect(instances).to receive(:insert).with(project: "e2e-project", zone:, instance_resource: instance).and_return(v1::Operation.new(name: "op-instance"))
      expect(Clog).to receive(:emit).with("GCP instance created", {gcp_instance_created: "#{customer_name}@#{zone}"}).and_call_original
      expect { vp_test.launch_client }.to hop("wait_client_result")
      expect(vp_test.client_zone).to eq zone
      expect(frame_value(vp_test, "create_client")).to eq("name" => "op-instance", "scope" => "zone", "scope_value" => zone)
    end

    it "adopts the client a previous attempt launched" do
      expect(instances).to receive(:insert).with(project: "e2e-project", zone:, instance_resource: instance).and_raise(Google::Cloud::AlreadyExistsError, "The resource already exists")
      expect { vp_test.launch_client }.to hop("wait_client_result")
      expect(vp_test.client_zone).to eq zone
      expect(frame_value(vp_test, "create_client")).to be_nil
    end

    it "fails the test when GCP refuses the launch, instead of retrying it" do
      expect(instances).to receive(:insert).and_raise(Google::Cloud::ResourceExhaustedError, "The zone does not have enough resources available to fulfill the request.")
      expect(Clog).not_to receive(:emit)
      expect { vp_test.launch_client }.to hop("destroy")
      expect(vp_test.fail_message).to eq "Could not launch the client instance: The zone does not have enough resources available to fulfill the request."
      expect(vp_test.client_zone).to be_nil
    end
  end

  describe "#wait_client_result" do
    before {
      provision
      refresh_frame(vp_test, new_values: {"client_zone" => zone})
      at_label("wait_client_result")
    }

    def console(text)
      expect(instances).to receive(:get_serial_port_output).with(project: "e2e-project", zone:, instance: customer_name).and_return(Google::Cloud::Compute::V1::SerialPortOutput.new(contents: text))
    end

    it "passes when port 5432 connects over the peering" do
      console("[  OK  ] Finished google-startup-scripts.service\r\nubie2e result tcp=ok\r\n")
      expect { vp_test.wait_client_result }.to hop("destroy")
      expect(vp_test.fail_message).to be_nil
    end

    it "fails the test when port 5432 does not connect" do
      console("ubie2e result tcp=fail\r\n")
      expect { vp_test.wait_client_result }.to hop("destroy")
      expect(vp_test.fail_message).to eq "From the customer network, TCP to #{pg_ip} port 5432 got fail, expected ok"
    end

    it "naps while the console has no result" do
      console("Ubuntu 24.04 LTS\r\n")
      expect { vp_test.wait_client_result }.to nap(5)
    end

    it "naps while the new instance is not visible yet" do
      expect(instances).to receive(:get_serial_port_output).and_raise(not_found, "not found")
      expect { vp_test.wait_client_result }.to nap(5)
    end

    it "naps while the new instance is not ready, under the deadline" do
      expect(instances).to receive(:get_serial_port_output).and_raise(Google::Cloud::InvalidArgumentError, "The resource 'projects/e2e-project/zones/#{zone}/instances/#{customer_name}' is not ready")
      expect { vp_test.wait_client_result }.to nap(5)
      expect(vp_test.label_deadlines["wait_client_result"]).to be_within(5).of(Time.now.to_i + 15 * 60)
    end

    it "raises other refusals" do
      expect(instances).to receive(:get_serial_port_output).and_raise(Google::Cloud::InvalidArgumentError, "Invalid value for field 'zone'")
      expect { vp_test.wait_client_result }.to raise_error(Google::Cloud::InvalidArgumentError, "Invalid value for field 'zone'")
    end

    it "fails the test when the serial output cannot be read" do
      expect(instances).to receive(:get_serial_port_output).and_raise(Google::Cloud::PermissionDeniedError, "Required 'compute.instances.getSerialPortOutput' permission")
      expect { vp_test.wait_client_result }.to hop("destroy")
      expect(vp_test.fail_message).to eq "Could not read the serial output of client instance #{customer_name}: Required 'compute.instances.getSerialPortOutput' permission"
    end

    describe "with the insert operation" do
      before { refresh_frame(vp_test, new_values: {"create_client" => {"name" => "op-instance", "scope" => "zone", "scope_value" => zone}}) }

      def expect_op
        expect(zone_ops).to receive(:get).with(project: "e2e-project", zone:, operation: "op-instance")
      end

      it "naps while the operation runs" do
        expect_op.and_return(v1::Operation.new(status: :RUNNING))
        expect(instances).not_to receive(:get_serial_port_output)
        expect { vp_test.wait_client_result }.to nap(5)
      end

      it "clears the operation once it is done and reads the console" do
        expect_op.and_return(v1::Operation.new(status: :DONE))
        console("ubie2e result tcp=ok\r\n")
        expect { vp_test.wait_client_result }.to hop("destroy")
        expect(frame_value(vp_test, "create_client")).to be_nil
        expect(vp_test.fail_message).to be_nil
      end

      it "fails the test with GCP's error when the launch failed" do
        expect_op.and_return(op_failed("ZONE_RESOURCE_POOL_EXHAUSTED", "The zone does not have enough resources available to fulfill the request."))
        expect(instances).not_to receive(:get_serial_port_output)
        expect { vp_test.wait_client_result }.to hop("destroy")
        expect(vp_test.fail_message).to eq "Client instance #{customer_name} could not be created: The zone does not have enough resources available to fulfill the request. (code: ZONE_RESOURCE_POOL_EXHAUSTED)"
      end
    end

    it "fails the test when the client reports nothing in time" do
      at_label("wait_client_result", expired: true)
      console("")
      expect { vp_test.wait_client_result }.to hop("destroy")
      expect(vp_test.fail_message).to eq "Client instance #{customer_name} reported no result within 15 minutes"
    end
  end

  describe "#destroy" do
    before { provision }

    it "hops to wait_peering_destroyed when the test failed before creating a client or a peering" do
      expect(instances).not_to receive(:delete)
      expect { vp_test.destroy }.to hop("wait_peering_destroyed")
    end

    it "deletes the client and destroys the peering" do
      request_peering
      refresh_frame(vp_test, new_values: {"client_zone" => zone})
      expect(instances).to receive(:delete).with(project: "e2e-project", zone:, instance: customer_name).and_return(v1::Operation.new(name: "op-delete"))
      expect { vp_test.destroy }.to hop("wait_peering_destroyed")
      expect(vpc_peering.destroy_set?(cached: false)).to be true
    end

    it "tolerates a client that GCP already deleted" do
      refresh_frame(vp_test, new_values: {"client_zone" => zone})
      expect(instances).to receive(:delete).with(project: "e2e-project", zone:, instance: customer_name).and_raise(not_found, "not found")
      expect { vp_test.destroy }.to hop("wait_peering_destroyed")
    end
  end

  describe "#wait_peering_destroyed" do
    before {
      provision
      at_label("wait_peering_destroyed")
    }

    def finish_peering
      request_peering
      peering_ubid = vpc_peering.ubid
      vpc_peering.destroy
      Strand[vp_test.vpc_peering_id].destroy
      at_label("wait_peering_destroyed")
      peering_ubid
    end

    it "hops to wait_client_deleted without checks when the test failed before requesting a peering" do
      refresh_frame(vp_test, new_values: {"fail_message" => "Earlier failure"})
      expect(networks).not_to receive(:get)
      expect { vp_test.wait_peering_destroyed }.to hop("wait_client_deleted")
      expect(vp_test.cascade_peering).to be_nil
    end

    it "naps while the peering exists" do
      request_peering
      expect(networks).not_to receive(:get)
      expect { vp_test.wait_peering_destroyed }.to nap(5)
    end

    it "fails the test when the peering is not destroyed within 10 minutes, skipping the GCP checks" do
      request_peering
      at_label("wait_peering_destroyed", expired: true)
      vpc_peering.incr_destroy
      expect(networks).not_to receive(:get)
      expect { vp_test.wait_peering_destroyed }.to hop("wait_client_deleted")
      expect(vp_test).to have_attributes(fail_message: "VPC peering was not destroyed within 10 minutes, it is deleting in start", cascade_peering: nil)
    end

    it "verifies our side is gone and the customer side went inactive, then requests a second peering for the PostgreSQL destroy" do
      finish_peering
      refresh_frame(vp_test, new_values: {"label_deadlines" => {"wait_peering_active" => Time.now.to_i - 1}})
      expect_network(ubicloud_network, half("other", "other-network"))
      expect_network(customer_name, customer_half(state: "INACTIVE"))
      expect { vp_test.wait_peering_destroyed }.to hop("request_peering")
      expect(vp_test).to have_attributes(fail_message: nil, cascade_peering: true, label_deadlines: nil)
    end

    it "hops to wait_client_deleted once the second peering is gone too" do
      finish_peering
      refresh_frame(vp_test, new_values: {"cascade_peering" => true})
      expect_network(ubicloud_network)
      expect_network_missing(customer_name)
      expect { vp_test.wait_peering_destroyed }.to hop("wait_client_deleted")
      expect(vp_test.fail_message).to be_nil
    end

    it "counts our side as gone when the Ubicloud network is" do
      finish_peering
      refresh_frame(vp_test, new_values: {"cascade_peering" => true})
      expect_network_missing(ubicloud_network)
      expect_network(customer_name, customer_half(state: "INACTIVE"))
      expect { vp_test.wait_peering_destroyed }.to hop("wait_client_deleted")
      expect(vp_test.fail_message).to be_nil
    end

    it "fails the test when our side outlived the peering, keeping earlier failures" do
      peering_ubid = finish_peering
      refresh_frame(vp_test, new_values: {"fail_message" => "Earlier failure"})
      expect_network(ubicloud_network, half("ubicloud-#{peering_ubid}", customer_name))
      expect { vp_test.wait_peering_destroyed }.to hop("wait_client_deleted")
      expect(vp_test.fail_message).to eq "Earlier failure; Ubicloud's side of the peering (ubicloud-#{peering_ubid}) is ACTIVE after the VPC peering was destroyed"
    end

    it "naps while the customer side is still active" do
      finish_peering
      expect_network(ubicloud_network)
      expect_network(customer_name, customer_half)
      expect { vp_test.wait_peering_destroyed }.to nap(5)
      expect(vp_test.fail_message).to be_nil
    end

    it "fails the test when the customer side stays active" do
      finish_peering
      at_label("wait_peering_destroyed", expired: true)
      expect_network(ubicloud_network)
      expect_network(customer_name, customer_half)
      expect { vp_test.wait_peering_destroyed }.to hop("wait_client_deleted")
      expect(vp_test.fail_message).to eq "Peering #{customer_name} on the customer network is ACTIVE after Ubicloud's side was removed, expected INACTIVE"
    end
  end

  describe "#wait_peering_cascade" do
    before {
      provision
      at_label("wait_peering_cascade")
    }

    it "naps while the peering exists" do
      request_peering
      expect(networks).not_to receive(:get)
      expect { vp_test.wait_peering_cascade }.to nap(5)
    end

    it "fails the test when the cascade does not destroy the peering within 20 minutes, then checks our side" do
      request_peering
      at_label("wait_peering_cascade", expired: true)
      expect_network(ubicloud_network, ubicloud_half)
      expect { vp_test.wait_peering_cascade }.to hop("wait_client_deleted")
      expect(vp_test.fail_message).to eq "VPC peering was not destroyed within 20 minutes of the PostgreSQL destroy, it is creating in start; " \
        "Ubicloud's side of the peering (ubicloud-#{vpc_peering.ubid}) is ACTIVE after the PostgreSQL destroy"
    end

    it "hops to wait_client_deleted once the subnet destroy removed the Ubicloud network" do
      GcpVpc[dedicated_for_subnet_id: private_subnet.id].destroy
      expect(networks).not_to receive(:get)
      expect { vp_test.wait_peering_cascade }.to hop("wait_client_deleted")
      expect(vp_test.fail_message).to be_nil
    end

    it "finds our side through the subnet's network after the subnet destroy dropped the join row" do
      DB[:private_subnet_gcp_vpc].where(private_subnet_id: private_subnet.id).delete
      expect_network(ubicloud_network, half("ubicloud-leaked", customer_name))
      expect { vp_test.wait_peering_cascade }.to hop("wait_client_deleted")
      expect(vp_test.fail_message).to eq "Ubicloud's side of the peering (ubicloud-leaked) is ACTIVE after the PostgreSQL destroy"
    end

    it "hops to wait_client_deleted once our side is gone from the Ubicloud network" do
      expect_network(ubicloud_network)
      expect { vp_test.wait_peering_cascade }.to hop("wait_client_deleted")
      expect(vp_test.fail_message).to be_nil
    end
  end

  describe "#wait_client_deleted" do
    before {
      provision
      at_label("wait_client_deleted")
    }

    it "hops to remove_customer_peering when no client was launched" do
      expect(instances).not_to receive(:get)
      expect { vp_test.wait_client_deleted }.to hop("remove_customer_peering")
    end

    describe "with a client" do
      before { refresh_frame(vp_test, new_values: {"client_zone" => zone}) }

      def expect_client
        expect(instances).to receive(:get).with(project: "e2e-project", zone:, instance: customer_name)
      end

      it "hops to remove_customer_peering once the client is gone" do
        expect_client.and_raise(not_found, "not found")
        expect { vp_test.wait_client_deleted }.to hop("remove_customer_peering")
      end

      it "naps while the client is deleted" do
        expect_client.and_return(v1::Instance.new(name: customer_name, status: "STOPPING"))
        expect { vp_test.wait_client_deleted }.to nap(5)
      end

      it "fails the test and leaves the customer network to the CI cleanup when the client is not deleted in time" do
        at_label("wait_client_deleted", expired: true)
        expect_client.and_return(v1::Instance.new(name: customer_name, status: "STOPPING"))
        expect { vp_test.wait_client_deleted }.to hop("destroy_postgres")
        expect(vp_test.fail_message).to eq "Client instance #{customer_name} was not deleted within 5 minutes"
      end
    end
  end

  describe "#remove_customer_peering" do
    before {
      provision
      at_label("remove_customer_peering")
    }

    def expect_remove
      expect(networks).to receive(:remove_peering).with(
        project: "e2e-project",
        network: customer_name,
        networks_remove_peering_request_resource: Google::Cloud::Compute::V1::NetworksRemovePeeringRequest.new(name: customer_name),
      )
    end

    it "hops to delete_customer_subnet when the customer network has no peering" do
      expect_network(customer_name)
      expect(networks).not_to receive(:remove_peering)
      expect { vp_test.remove_customer_peering }.to hop("delete_customer_subnet")
    end

    it "hops to delete_customer_subnet when the customer network is gone" do
      expect_network_missing(customer_name)
      expect(networks).not_to receive(:remove_peering)
      expect { vp_test.remove_customer_peering }.to hop("delete_customer_subnet")
    end

    describe "with the customer side" do
      before { expect_network(customer_name, customer_half(state: "INACTIVE")) }

      it "removes it" do
        expect_remove.and_return(v1::Operation.new(name: "op-remove"))
        expect { vp_test.remove_customer_peering }.to hop("wait_customer_peering_removed")
      end

      it "hops to wait_customer_peering_removed when it disappeared under the removal" do
        expect_remove.and_raise(not_found, "not found")
        expect { vp_test.remove_customer_peering }.to hop("wait_customer_peering_removed")
      end

      it "naps while another peering operation runs" do
        expect_remove.and_raise(Google::Cloud::InvalidArgumentError, "There is a peering operation in progress on the local or peer network. Try again later.")
        expect { vp_test.remove_customer_peering }.to nap(15)
      end

      it "raises other refusals" do
        expect_remove.and_raise(Google::Cloud::InvalidArgumentError, "Invalid value for field 'name'")
        expect { vp_test.remove_customer_peering }.to raise_error(Google::Cloud::InvalidArgumentError, "Invalid value for field 'name'")
      end
    end
  end

  describe "#wait_customer_peering_removed" do
    before {
      provision
      at_label("wait_customer_peering_removed")
    }

    it "hops to delete_customer_subnet once the customer side is gone" do
      expect_network(customer_name)
      expect { vp_test.wait_customer_peering_removed }.to hop("delete_customer_subnet")
    end

    it "naps while the customer side is removed" do
      expect_network(customer_name, customer_half(state: "INACTIVE"))
      expect { vp_test.wait_customer_peering_removed }.to nap(5)
    end

    it "fails the test and leaves the customer network to the CI cleanup when the customer side stays" do
      at_label("wait_customer_peering_removed", expired: true)
      expect_network(customer_name, customer_half(state: "INACTIVE"))
      expect { vp_test.wait_customer_peering_removed }.to hop("destroy_postgres")
      expect(vp_test.fail_message).to eq "Peering #{customer_name} on the customer network was not removed within 5 minutes"
    end
  end

  describe "#delete_customer_subnet" do
    before {
      provision
      at_label("delete_customer_subnet")
    }

    def expect_delete
      expect(subnetworks).to receive(:delete).with(project: "e2e-project", region: "us-central1", subnetwork: customer_name)
    end

    it "deletes the subnet" do
      expect_delete.and_return(v1::Operation.new(name: "op-delete"))
      expect { vp_test.delete_customer_subnet }.to hop("wait_customer_subnet_deleted")
    end

    it "hops on when the subnet is already gone" do
      expect_delete.and_raise(not_found, "not found")
      expect { vp_test.delete_customer_subnet }.to hop("wait_customer_subnet_deleted")
    end

    it "naps while the client network interface is released" do
      expect_delete.and_raise(in_use("subnetwork"))
      expect { vp_test.delete_customer_subnet }.to nap(5)
    end

    it "fails the test and leaves the customer network to the CI cleanup when the subnet stays in use" do
      at_label("delete_customer_subnet", expired: true)
      expect_delete.and_raise(in_use("subnetwork"))
      expect { vp_test.delete_customer_subnet }.to hop("destroy_postgres")
      expect(vp_test.fail_message).to eq "Customer subnet #{customer_name} could not be deleted within 5 minutes"
    end

    it "raises other refusals" do
      expect_delete.and_raise(Google::Cloud::InvalidArgumentError, "Invalid value for field 'subnetwork'")
      expect { vp_test.delete_customer_subnet }.to raise_error(Google::Cloud::InvalidArgumentError, "Invalid value for field 'subnetwork'")
    end
  end

  describe "#wait_customer_subnet_deleted" do
    before {
      provision
      at_label("wait_customer_subnet_deleted")
    }

    def expect_subnet
      expect(subnetworks).to receive(:get).with(project: "e2e-project", region: "us-central1", subnetwork: customer_name)
    end

    it "hops to delete_customer_network once the subnet is gone" do
      expect_subnet.and_raise(not_found, "not found")
      expect { vp_test.wait_customer_subnet_deleted }.to hop("delete_customer_network")
    end

    it "naps while the subnet is deleted" do
      expect_subnet.and_return(v1::Subnetwork.new(name: customer_name))
      expect { vp_test.wait_customer_subnet_deleted }.to nap(5)
    end

    it "fails the test and leaves the customer network to the CI cleanup when the subnet is not deleted in time" do
      at_label("wait_customer_subnet_deleted", expired: true)
      expect_subnet.and_return(v1::Subnetwork.new(name: customer_name))
      expect { vp_test.wait_customer_subnet_deleted }.to hop("destroy_postgres")
      expect(vp_test.fail_message).to eq "Customer subnet #{customer_name} was not deleted within 5 minutes"
    end
  end

  describe "#delete_customer_network" do
    before {
      provision
      at_label("delete_customer_network")
    }

    def expect_delete
      expect(networks).to receive(:delete).with(project: "e2e-project", network: customer_name)
    end

    it "deletes the network" do
      expect_delete.and_return(v1::Operation.new(name: "op-delete"))
      expect { vp_test.delete_customer_network }.to hop("wait_customer_network_deleted")
    end

    it "naps while the network is still in use" do
      expect_delete.and_raise(in_use("network"))
      expect { vp_test.delete_customer_network }.to nap(5)
    end

    it "fails the test and leaves the network to the CI cleanup when it stays in use" do
      at_label("delete_customer_network", expired: true)
      expect_delete.and_raise(in_use("network"))
      expect { vp_test.delete_customer_network }.to hop("destroy_postgres")
      expect(vp_test.fail_message).to eq "Customer network #{customer_name} could not be deleted within 5 minutes"
    end
  end

  describe "#wait_customer_network_deleted" do
    before {
      provision
      at_label("wait_customer_network_deleted")
    }

    it "hops to destroy_postgres once the network is gone" do
      expect_network_missing(customer_name)
      expect { vp_test.wait_customer_network_deleted }.to hop("destroy_postgres")
      expect(vp_test.fail_message).to be_nil
    end

    it "naps while the network is deleted" do
      expect_network(customer_name)
      expect { vp_test.wait_customer_network_deleted }.to nap(5)
    end

    it "fails the test when the network is not deleted in time" do
      at_label("wait_customer_network_deleted", expired: true)
      expect_network(customer_name)
      expect { vp_test.wait_customer_network_deleted }.to hop("destroy_postgres")
      expect(vp_test.fail_message).to eq "Customer network #{customer_name} was not deleted within 5 minutes"
    end
  end
end
