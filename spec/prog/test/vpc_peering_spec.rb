# frozen_string_literal: true

require "aws-sdk-ec2"
require_relative "../../model/spec_helper"

RSpec.describe Prog::Test::VpcPeering do
  subject(:vp_test) { described_class.new(st) }

  let(:st) { described_class.assemble }
  let(:service_project) { Project.create(name: "service-project") }
  let(:client) { Aws::EC2::Client.new(stub_responses: true) }
  let(:customer_cidr) { "192.168.240.0/24" }
  let(:customer_name) { "vpc-peering-e2e-#{st.ubid}" }
  let(:customer_vpc) { "vpc-0bbbbbbbbbbbbbbbb" }
  let(:customer_subnet) { "subnet-0bbbbbbbbbbbbbbbb" }
  let(:account) { "111122223333" }
  let(:our_vpc) { "vpc-0aaaaaaaaaaaaaaaa" }
  let(:rtb) { "rtb-0aaaaaaaaaaaaaaaa" }
  let(:pcx_id) { "pcx-0123456789abcdef0" }
  let(:client_instance) { "i-0cccccccccccccccc" }
  let(:pg_hostname) { "ec2-203-0-113-7.us-west-2.compute.amazonaws.com" }
  let(:private_subnet) { vp_test.private_subnet }
  let(:vpc_peering) { VpcPeering[vp_test.vpc_peering_id] }

  before do
    allow(Config).to receive(:postgres_service_project_id).and_return(service_project.id)
    credentials = Aws::Credentials.new("stubbed-akid", "stubbed-secret")
    allow(Aws::Credentials).to receive(:new).with("stubbed-akid", "stubbed-secret").and_return(credentials)
    allow(Aws::EC2::Client).to receive(:new).with(credentials:, region: "us-west-2").and_return(client)
  end

  def start_test
    expect(Config).to receive_messages(e2e_aws_assume_role: nil, e2e_aws_access_key: "stubbed-akid", e2e_aws_secret_key: "stubbed-secret")
    client.stub_responses(:describe_availability_zones, availability_zones: [{zone_name: "us-west-2a", zone_id: "usw2-az1"}])
    expect { vp_test.start }.to hop("wait_postgres_resource")
  end

  def provision
    start_test
    vp_test.postgres_resource.strand.update(label: "wait")
    private_subnet.private_subnet_aws_resource.update(vpc_id: our_vpc, route_table_id: rtb)
    AwsInstance.create_with_id(vp_test.representative_server.vm, instance_id: "i-0aaaaaaaaaaaaaaaa", az_id: "usw2-az2", ipv4_dns_name: pg_hostname)
  end

  def request_peering
    refresh_frame(vp_test, new_values: {"customer_account_id" => account, "customer_vpc_id" => customer_vpc})
    expect { vp_test.request_peering }.to hop("wait_peering_requested")
  end

  def record_connection
    vpc_peering.vpc_peering_aws_resource.update(peering_connection_id: pcx_id, requester_account_id: account)
    refresh_frame(vp_test, new_values: {"peering_connection_id" => pcx_id})
  end

  def at_label(label, expired: false)
    st.update(label:)
    refresh_frame(vp_test, new_values: {"label_deadlines" => {label => Time.now.to_i - 1}}) if expired
  end

  def connection(code, dns: true)
    {vpc_peering_connection_id: pcx_id, status: {code:}, requester_vpc_info: {peering_options: {allow_dns_resolution_from_remote_vpc: dns}}}
  end

  def stub_routes(*routes)
    client.stub_responses(:describe_route_tables, route_tables: [{route_table_id: rtb, routes: [{destination_cidr_block: "0.0.0.0/0", gateway_id: "igw-0aaaaaaaaaaaaaaaa", state: "active"}, *routes]}])
  end

  def peering_route(state: "active")
    {destination_cidr_block: customer_cidr, vpc_peering_connection_id: pcx_id, state:}
  end

  describe ".assemble" do
    it "creates an AWS test strand with its own project" do
      expect { st }.to change { Project.select_order_map(:name) }.from(["service-project"]).to(["Vpc-Peering-Test-Project", "service-project"])
      expect(st).to have_attributes(prog: "Test::VpcPeering", label: "start")
      expect(st.stack.first).to include("provider" => "aws", "aws_location_name" => "us-west-2")
    end
  end

  describe "#start" do
    it "creates a BYOC location with the E2E credential and a PostgreSQL resource in it" do
      start_test
      location = Location[vp_test.location_id]
      expect(location).to have_attributes(name: "us-west-2", provider: "aws", project_id: vp_test.postgres_test_project_id, byoc: true, display_name: "vpc-peering-e2e")
      expect(Strand[location.id]).to have_attributes(prog: "LocationNexus", label: "wait")
      expect(location.location_credential_aws).to have_attributes(access_key: "stubbed-akid", secret_key: "stubbed-secret")
      expect(location.location_azs.map(&:zone_id)).to eq ["usw2-az1"]
      expect(vp_test.postgres_resource).to have_attributes(location_id: location.id, target_vm_size: "m8gd.large", target_storage_size_gib: 118)
      expect(vp_test.private_subnet_id).to eq vp_test.postgres_resource.private_subnet_id
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

    it "hops to create_customer_vpc once PostgreSQL answers" do
      expect(sshable).to receive(:_cmd).and_return("1\n")
      expect { vp_test.wait_postgres_resource }.to hop("create_customer_vpc")
    end
  end

  describe "#create_customer_vpc" do
    before { provision }

    let(:tag_query) { {filters: [{name: "tag:Name", values: [customer_name]}]} }

    it "creates a tagged customer VPC" do
      client.stub_responses(:describe_vpcs, vpcs: [])
      client.stub_responses(:create_vpc, vpc: {vpc_id: customer_vpc, owner_id: account})
      expect(client).to receive(:describe_vpcs).with(tag_query).and_call_original
      expect(client).to receive(:create_vpc).with(cidr_block: customer_cidr, tag_specifications: Util.aws_tag_specifications("vpc", customer_name)).and_call_original
      expect { vp_test.create_customer_vpc }.to hop("wait_customer_vpc")
      expect(vp_test).to have_attributes(customer_vpc_id: customer_vpc, customer_account_id: account)
    end

    it "adopts the customer VPC a previous attempt created" do
      client.stub_responses(:describe_vpcs, vpcs: [{vpc_id: customer_vpc, owner_id: account}])
      expect(client).not_to receive(:create_vpc)
      expect { vp_test.create_customer_vpc }.to hop("wait_customer_vpc")
      expect(vp_test).to have_attributes(customer_vpc_id: customer_vpc, customer_account_id: account)
    end
  end

  describe "#wait_customer_vpc" do
    before {
      provision
      refresh_frame(vp_test, new_values: {"customer_vpc_id" => customer_vpc})
    }

    it "naps until the customer VPC is available" do
      client.stub_responses(:describe_vpcs, vpcs: [])
      expect(client).to receive(:describe_vpcs).with(filters: [{name: "vpc-id", values: [customer_vpc]}, {name: "state", values: ["available"]}]).and_call_original
      expect(client).not_to receive(:modify_vpc_attribute)
      expect { vp_test.wait_customer_vpc }.to nap(5)
    end

    it "turns on DNS support and hostnames" do
      client.stub_responses(:describe_vpcs, vpcs: [{vpc_id: customer_vpc, state: "available"}])
      expect(client).to receive(:modify_vpc_attribute).with(vpc_id: customer_vpc, enable_dns_support: {value: true}).and_call_original.ordered
      expect(client).to receive(:modify_vpc_attribute).with(vpc_id: customer_vpc, enable_dns_hostnames: {value: true}).and_call_original.ordered
      expect { vp_test.wait_customer_vpc }.to hop("create_customer_subnet")
    end
  end

  describe "#create_customer_subnet" do
    before {
      provision
      refresh_frame(vp_test, new_values: {"customer_vpc_id" => customer_vpc})
    }

    it "creates a tagged subnet in the AZ of the PostgreSQL server" do
      client.stub_responses(:describe_subnets, subnets: [])
      client.stub_responses(:create_subnet, subnet: {subnet_id: customer_subnet})
      expect(client).to receive(:describe_subnets).with(filters: [{name: "vpc-id", values: [customer_vpc]}]).and_call_original
      expect(client).to receive(:create_subnet).with(vpc_id: customer_vpc, cidr_block: customer_cidr, availability_zone_id: "usw2-az2",
        tag_specifications: Util.aws_tag_specifications("subnet", customer_name)).and_call_original
      expect { vp_test.create_customer_subnet }.to hop("request_peering")
      expect(vp_test.customer_subnet_id).to eq customer_subnet
    end

    it "adopts the subnet a previous attempt created" do
      client.stub_responses(:describe_subnets, subnets: [{subnet_id: customer_subnet}])
      expect(client).not_to receive(:create_subnet)
      expect { vp_test.create_customer_subnet }.to hop("request_peering")
      expect(vp_test.customer_subnet_id).to eq customer_subnet
    end
  end

  describe "#request_peering" do
    it "requests a peering of the database subnet with the customer VPC" do
      provision
      request_peering
      expect(vpc_peering).to have_attributes(private_subnet_id: private_subnet.id, peer_account_id: account, peer_vpc_id: customer_vpc, state: "creating")
      expect(vpc_peering.vpc_peering_aws_resource.peer_region).to eq "us-west-2"
      expect(Strand[vpc_peering.id]).to have_attributes(prog: "Vnet::Aws::VpcPeeringNexus", label: "start")
    end
  end

  describe "#wait_peering_requested" do
    before {
      provision
      request_peering
      at_label("wait_peering_requested")
    }

    it "records the connection and hops to accept_peering once the request waits for the peer" do
      vpc_peering.update(state: "waiting_for_peer")
      vpc_peering.vpc_peering_aws_resource.update(peering_connection_id: pcx_id, requester_account_id: account)
      expect { vp_test.wait_peering_requested }.to hop("accept_peering")
      expect(vp_test.peering_connection_id).to eq pcx_id
    end

    it "fails the test when the peering fails" do
      vpc_peering.update(state: "failed", state_message: "AWS refused the peering request")
      expect { vp_test.wait_peering_requested }.to hop("destroy")
      expect(vp_test.fail_message).to eq "VPC peering failed: AWS refused the peering request"
    end

    it "naps while the request is being created" do
      expect { vp_test.wait_peering_requested }.to nap(5)
      expect(vp_test.label_deadlines["wait_peering_requested"]).to be_within(5).of(Time.now.to_i + 5 * 60)
      expect(vp_test.fail_message).to be_nil
    end

    it "fails the test when the request is not sent in time" do
      at_label("wait_peering_requested", expired: true)
      expect { vp_test.wait_peering_requested }.to hop("destroy")
      expect(vp_test.fail_message).to eq "VPC peering was not requested within 5 minutes, state creating"
    end
  end

  describe "#accept_peering" do
    it "accepts the peering connection as the customer" do
      provision
      request_peering
      record_connection
      expect(client).to receive(:accept_vpc_peering_connection).with(vpc_peering_connection_id: pcx_id).and_call_original
      expect { vp_test.accept_peering }.to hop("wait_peering_active")
    end

    it "hops to wait_peering_active when the connection is no longer pending acceptance" do
      provision
      request_peering
      record_connection
      client.stub_responses(:accept_vpc_peering_connection, "InvalidStateTransition")
      expect { vp_test.accept_peering }.to hop("wait_peering_active")
    end
  end

  describe "#wait_peering_active" do
    before {
      provision
      request_peering
      record_connection
      at_label("wait_peering_active")
    }

    let(:peering_strand) { Strand[vpc_peering.id] }

    def activate(cidrs: [customer_cidr])
      vpc_peering.update(state: "active", peer_cidrs: Sequel.pg_array(cidrs, :cidr))
      peering_strand.update(label: "wait", schedule: Time.now + 15 * 60)
    end

    it "hops to add_customer_route once our side routes the customer VPC with DNS resolution on" do
      activate
      stub_routes(peering_route)
      client.stub_responses(:describe_vpc_peering_connections, vpc_peering_connections: [connection("active")])
      expect(client).to receive(:describe_route_tables).with(route_table_ids: [rtb]).and_call_original
      expect(client).to receive(:describe_vpc_peering_connections).with(vpc_peering_connection_ids: [pcx_id]).and_call_original
      expect { vp_test.wait_peering_active }.to hop("add_customer_route")
      expect(vp_test.fail_message).to be_nil
    end

    it "hops to destroy_peered_postgres once the cascade peering is active" do
      refresh_frame(vp_test, new_values: {"cascade_peering" => true})
      activate
      stub_routes(peering_route)
      client.stub_responses(:describe_vpc_peering_connections, vpc_peering_connections: [connection("active")])
      expect { vp_test.wait_peering_active }.to hop("destroy_peered_postgres")
      expect(vp_test.fail_message).to be_nil
    end

    it "naps while our side does not show the DNS resolution option yet" do
      activate
      stub_routes(peering_route)
      client.stub_responses(:describe_vpc_peering_connections, vpc_peering_connections: [connection("active", dns: false)])
      expect { vp_test.wait_peering_active }.to nap(5)
      expect(vp_test.label_deadlines["wait_peering_active"]).to be_within(5).of(Time.now.to_i + 5 * 60)
      expect(vp_test.fail_message).to be_nil
    end

    describe "once the deadline passed" do
      before { at_label("wait_peering_active", expired: true) }

      it "fails the test when the peering claims other CIDR blocks" do
        activate(cidrs: [])
        stub_routes
        expect { vp_test.wait_peering_active }.to hop("destroy")
        expect(vp_test.fail_message).to eq "VPC peering routes [], expected [#{customer_cidr}]"
      end

      it "fails the test when our route table lacks an active route through the connection" do
        activate
        stub_routes(peering_route(state: "blackhole"))
        expect { vp_test.wait_peering_active }.to hop("destroy")
        expect(vp_test.fail_message).to eq "Route table #{rtb} has [[\"#{customer_cidr}\", \"blackhole\"]] through #{pcx_id}, expected an active route to #{customer_cidr}"
      end

      it "fails the test when DNS resolution from the customer VPC is off" do
        activate
        stub_routes(peering_route)
        client.stub_responses(:describe_vpc_peering_connections, vpc_peering_connections: [connection("active", dns: false)])
        expect { vp_test.wait_peering_active }.to hop("destroy")
        expect(vp_test.fail_message).to eq "Peering connection #{pcx_id} does not allow DNS resolution from the peer VPC"
      end

      describe "with our side routed and DNS resolution on" do
        before do
          activate
          stub_routes(peering_route)
          client.stub_responses(:describe_vpc_peering_connections, vpc_peering_connections: [connection("active")])
        end

        it "fails the test when the peering is not in wait" do
          peering_strand.update(label: "configure")
          expect { vp_test.wait_peering_active }.to hop("destroy")
          expect(vp_test.fail_message).to eq "VPC peering has not settled in wait, it is in configure (try 0)"
        end

        it "fails the test when the peering keeps failing in wait" do
          peering_strand.update(try: 9)
          expect { vp_test.wait_peering_active }.to hop("destroy")
          expect(vp_test.fail_message).to eq "VPC peering has not settled in wait, it is in wait (try 9)"
        end

        it "fails the test when wait did not take its long nap" do
          peering_strand.update(schedule: Time.now + 5)
          expect { vp_test.wait_peering_active }.to hop("destroy")
          expect(vp_test.fail_message).to eq "VPC peering has not settled in wait, it is in wait (try 0)"
        end

        it "fails the test when the peering shows warnings" do
          vpc_peering.update(state_message: "Private DNS is off")
          expect { vp_test.wait_peering_active }.to hop("destroy")
          expect(vp_test.fail_message).to eq "VPC peering is active with warnings: Private DNS is off"
        end
      end
    end

    it "fails the test when the peering fails" do
      vpc_peering.update(state: "failed", state_message: "The peering request expired")
      expect { vp_test.wait_peering_active }.to hop("destroy")
      expect(vp_test.fail_message).to eq "VPC peering failed: The peering request expired"
    end

    it "naps while the peering is configured" do
      vpc_peering.update(state: "configuring")
      expect { vp_test.wait_peering_active }.to nap(5)
    end

    it "fails the test when the peering does not become active in time" do
      vpc_peering.update(state: "configuring")
      at_label("wait_peering_active", expired: true)
      expect { vp_test.wait_peering_active }.to hop("destroy")
      expect(vp_test.fail_message).to eq "VPC peering did not become active within 5 minutes, state configuring"
    end
  end

  describe "#add_customer_route" do
    it "routes the database subnet through the connection from the customer main route table" do
      provision
      refresh_frame(vp_test, new_values: {"customer_vpc_id" => customer_vpc, "peering_connection_id" => pcx_id})
      client.stub_responses(:describe_route_tables, route_tables: [{route_table_id: "rtb-0bbbbbbbbbbbbbbbb"}])
      expect(client).to receive(:describe_route_tables).with(filters: [{name: "vpc-id", values: [customer_vpc]}, {name: "association.main", values: ["true"]}]).and_call_original
      expect(client).to receive(:create_route).with(route_table_id: "rtb-0bbbbbbbbbbbbbbbb", destination_cidr_block: private_subnet.net4.to_s, vpc_peering_connection_id: pcx_id).and_call_original
      expect { vp_test.add_customer_route }.to hop("launch_client")
    end

    it "hops to launch_client when an earlier attempt added the route" do
      provision
      refresh_frame(vp_test, new_values: {"customer_vpc_id" => customer_vpc, "peering_connection_id" => pcx_id})
      client.stub_responses(:describe_route_tables, route_tables: [{route_table_id: "rtb-0bbbbbbbbbbbbbbbb"}])
      client.stub_responses(:create_route, "RouteAlreadyExists")
      expect { vp_test.add_customer_route }.to hop("launch_client")
    end
  end

  describe "#launch_client" do
    it "launches a tagged client from the newest Amazon Linux image with a script probing the database hostname" do
      provision
      refresh_frame(vp_test, new_values: {"customer_subnet_id" => customer_subnet})
      client.stub_responses(:describe_images, images: [
        {image_id: "ami-0old", creation_date: "2026-09-01T00:00:00.000Z"},
        {image_id: "ami-0new", creation_date: "2026-10-01T00:00:00.000Z"},
      ])
      client.stub_responses(:run_instances, instances: [{instance_id: client_instance}])
      expect(client).to receive(:describe_images).with(owners: ["amazon"], filters: [{name: "name", values: ["al2023-ami-2023.*-arm64"]}]).and_call_original
      expect(client).to receive(:run_instances).with(
        image_id: "ami-0new",
        instance_type: "t4g.nano",
        min_count: 1,
        max_count: 1,
        subnet_id: customer_subnet,
        user_data: satisfy { |data|
          script = Base64.strict_decode64(data)
          script.start_with?("#!/bin/bash\n") && script.include?("\nhost=#{pg_hostname}\n") && script.include?("/dev/tcp/${addrs%%,*}/5432")
        },
        instance_initiated_shutdown_behavior: "terminate",
        metadata_options: {http_tokens: "required"},
        client_token: "#{st.ubid}-client",
        tag_specifications: Util.aws_tag_specifications("instance", customer_name) + Util.aws_tag_specifications("volume", customer_name),
      ).and_call_original
      expect { vp_test.launch_client }.to hop("wait_client_result")
      expect(vp_test.client_instance_id).to eq client_instance
    end

    it "fails the test when no image matches" do
      provision
      client.stub_responses(:describe_images, images: [])
      expect(client).not_to receive(:run_instances)
      expect { vp_test.launch_client }.to hop("destroy")
      expect(vp_test.fail_message).to eq "No Amazon Linux image matches al2023-ami-2023.*-arm64"
    end

    it "fails the test when AWS refuses the launch, instead of retrying it" do
      provision
      refresh_frame(vp_test, new_values: {"customer_subnet_id" => customer_subnet})
      client.stub_responses(:describe_images, images: [{image_id: "ami-0new", creation_date: "2026-10-01T00:00:00.000Z"}])
      client.stub_responses(:run_instances, Aws::EC2::Errors::InsufficientInstanceCapacity.new(nil, "We currently do not have sufficient t4g.nano capacity in the Availability Zone you requested (us-west-2b)."))
      expect { vp_test.launch_client }.to hop("destroy")
      expect(vp_test.fail_message).to eq "Could not launch the client instance: InsufficientInstanceCapacity: We currently do not have sufficient t4g.nano capacity in the Availability Zone you requested (us-west-2b)."
      expect(vp_test.client_instance_id).to be_nil
    end
  end

  describe "#wait_client_result" do
    before {
      provision
      refresh_frame(vp_test, new_values: {"client_instance_id" => client_instance})
      at_label("wait_client_result")
    }

    def console(text)
      client.stub_responses(:get_console_output, instance_id: client_instance, output: Base64.strict_encode64(text))
    end

    let(:private_ip) { private_subnet.net4.nth(5).to_s }

    it "passes when the database hostname resolves into the subnet and port 5432 connects" do
      console("[  OK  ] Started cloud-final.service\r\nubie2e result addrs=#{private_ip} tcp=ok\r\n")
      expect(client).to receive(:get_console_output).with(instance_id: client_instance, latest: true).and_call_original
      expect { vp_test.wait_client_result }.to hop("destroy")
      expect(vp_test.fail_message).to be_nil
    end

    it "fails the test when port 5432 does not connect" do
      console("ubie2e result addrs=none tcp=fail\r\n")
      expect { vp_test.wait_client_result }.to hop("destroy")
      expect(vp_test.fail_message).to eq "From the peer VPC, #{pg_hostname} resolved to none and TCP to port 5432 got fail, expected addresses in #{private_subnet.net4} and ok"
    end

    it "fails the test when the hostname resolves outside the subnet" do
      console("ubie2e result addrs=#{private_ip},203.0.113.7 tcp=ok\r\n")
      expect { vp_test.wait_client_result }.to hop("destroy")
      expect(vp_test.fail_message).to eq "From the peer VPC, #{pg_hostname} resolved to #{private_ip},203.0.113.7 and TCP to port 5432 got ok, expected addresses in #{private_subnet.net4} and ok"
    end

    it "naps while the console has no output" do
      client.stub_responses(:get_console_output, instance_id: client_instance)
      expect { vp_test.wait_client_result }.to nap(5)
    end

    it "naps while the console has no result" do
      console("Amazon Linux 2023\r\n")
      expect { vp_test.wait_client_result }.to nap(5)
    end

    it "naps while the new instance is not visible yet" do
      client.stub_responses(:get_console_output, "InvalidInstanceIDNotFound")
      expect { vp_test.wait_client_result }.to nap(5)
    end

    it "fails the test when the client reports nothing in time" do
      at_label("wait_client_result", expired: true)
      console("")
      expect { vp_test.wait_client_result }.to hop("destroy")
      expect(vp_test.fail_message).to eq "Client instance #{client_instance} reported no result within 15 minutes"
    end
  end

  describe "#destroy" do
    before { provision }

    it "hops to wait_peering_destroyed when the test failed before creating customer resources" do
      expect(client).not_to receive(:terminate_instances)
      expect { vp_test.destroy }.to hop("wait_peering_destroyed")
    end

    it "terminates the client and destroys the peering, recording its connection" do
      request_peering
      record_connection
      refresh_frame(vp_test, new_values: {"client_instance_id" => client_instance, "peering_connection_id" => nil})
      expect(client).to receive(:terminate_instances).with(instance_ids: [client_instance]).and_call_original
      expect { vp_test.destroy }.to hop("wait_peering_destroyed")
      expect(vpc_peering.destroy_set?(cached: false)).to be true
      expect(vp_test.peering_connection_id).to eq pcx_id
    end

    it "tolerates a client that AWS already forgot" do
      refresh_frame(vp_test, new_values: {"client_instance_id" => client_instance})
      client.stub_responses(:terminate_instances, "InvalidInstanceIDNotFound")
      expect(client).to receive(:terminate_instances).with(instance_ids: [client_instance]).and_call_original
      expect { vp_test.destroy }.to hop("wait_peering_destroyed")
    end
  end

  describe "#wait_peering_destroyed" do
    before {
      provision
      at_label("wait_peering_destroyed")
    }

    it "hops to wait_client_terminated without checks when the test failed before a connection was recorded" do
      refresh_frame(vp_test, new_values: {"fail_message" => "Earlier failure"})
      expect(client).not_to receive(:describe_vpc_peering_connections)
      expect { vp_test.wait_peering_destroyed }.to hop("wait_client_terminated")
      expect(vp_test.cascade_peering).to be_nil
    end

    it "naps while the peering exists" do
      request_peering
      expect { vp_test.wait_peering_destroyed }.to nap(5)
    end

    it "fails the test when the peering is not destroyed within 10 minutes, skipping the AWS checks" do
      request_peering
      at_label("wait_peering_destroyed", expired: true)
      refresh_frame(vp_test, new_values: {"peering_connection_id" => pcx_id})
      vpc_peering.incr_destroy
      expect(client).not_to receive(:describe_vpc_peering_connections)
      expect { vp_test.wait_peering_destroyed }.to hop("wait_client_terminated")
      expect(vp_test).to have_attributes(fail_message: "VPC peering was not destroyed within 10 minutes, it is deleting in start", cascade_peering: nil)
    end

    it "reports a peering whose strand finished between the two reads" do
      request_peering
      at_label("wait_peering_destroyed", expired: true)
      Strand[vp_test.vpc_peering_id].destroy
      expect { vp_test.wait_peering_destroyed }.to hop("wait_client_terminated")
      expect(vp_test.fail_message).to eq "VPC peering was not destroyed within 10 minutes, it is creating in "
    end

    it "verifies the connection and our routes are gone, then requests a second peering for the PostgreSQL destroy" do
      refresh_frame(vp_test, new_values: {"peering_connection_id" => pcx_id, "label_deadlines" => {"wait_peering_active" => Time.now.to_i - 1}})
      client.stub_responses(:describe_vpc_peering_connections, vpc_peering_connections: [connection("deleted")])
      stub_routes
      expect(client).to receive(:describe_vpc_peering_connections).with(vpc_peering_connection_ids: [pcx_id]).and_call_original
      expect(client).not_to receive(:delete_vpc_peering_connection)
      expect { vp_test.wait_peering_destroyed }.to hop("request_peering")
      expect(vp_test).to have_attributes(fail_message: nil, cascade_peering: true, label_deadlines: nil)
    end

    it "hops to wait_client_terminated once the second peering is gone too" do
      refresh_frame(vp_test, new_values: {"peering_connection_id" => pcx_id, "cascade_peering" => true})
      client.stub_responses(:describe_vpc_peering_connections, "InvalidVpcPeeringConnectionIDNotFound")
      stub_routes
      expect { vp_test.wait_peering_destroyed }.to hop("wait_client_terminated")
      expect(vp_test.fail_message).to be_nil
    end

    it "fails the test and deletes a connection that outlived the peering" do
      refresh_frame(vp_test, new_values: {"peering_connection_id" => pcx_id})
      client.stub_responses(:describe_vpc_peering_connections, vpc_peering_connections: [connection("active")])
      stub_routes
      expect(client).to receive(:delete_vpc_peering_connection).with(vpc_peering_connection_id: pcx_id).and_call_original
      expect { vp_test.wait_peering_destroyed }.to hop("wait_client_terminated")
      expect(vp_test.fail_message).to eq "Peering connection #{pcx_id} is active after the VPC peering was destroyed"
    end

    it "fails the test when our routes through the connection remain, keeping earlier failures" do
      refresh_frame(vp_test, new_values: {"peering_connection_id" => pcx_id, "fail_message" => "Earlier failure"})
      client.stub_responses(:describe_vpc_peering_connections, vpc_peering_connections: [connection("deleted")])
      stub_routes(peering_route(state: "blackhole"))
      expect { vp_test.wait_peering_destroyed }.to hop("wait_client_terminated")
      expect(vp_test.fail_message).to eq "Earlier failure; Route table #{rtb} still routes [\"#{customer_cidr}\"] through #{pcx_id}"
    end
  end

  describe "#destroy_peered_postgres" do
    it "destroys the PostgreSQL resource while its peering is active, recording its timelines" do
      provision
      timeline_id = vp_test.representative_server.timeline_id
      expect { vp_test.destroy_peered_postgres }.to hop("wait_peering_cascade")
      expect(vp_test.timeline_ids).to eq [timeline_id]
      expect(vp_test.postgres_resource.destroy_set?(cached: false)).to be true
    end
  end

  describe "#wait_peering_cascade" do
    before {
      provision
      at_label("wait_peering_cascade")
    }

    it "naps while the peering exists" do
      request_peering
      expect(client).not_to receive(:describe_vpc_peering_connections)
      expect { vp_test.wait_peering_cascade }.to nap(5)
    end

    it "fails the test when the cascade does not destroy the peering within 20 minutes, then checks the connection" do
      request_peering
      at_label("wait_peering_cascade", expired: true)
      refresh_frame(vp_test, new_values: {"peering_connection_id" => pcx_id})
      client.stub_responses(:describe_vpc_peering_connections, vpc_peering_connections: [connection("deleting")])
      expect(client).not_to receive(:delete_vpc_peering_connection)
      expect { vp_test.wait_peering_cascade }.to hop("wait_client_terminated")
      expect(vp_test.fail_message).to eq "VPC peering was not destroyed within 20 minutes of the PostgreSQL destroy, it is creating in start"
    end

    describe "once the peering is gone" do
      before { refresh_frame(vp_test, new_values: {"peering_connection_id" => pcx_id}) }

      it "verifies the connection is gone and hops to wait_client_terminated" do
        client.stub_responses(:describe_vpc_peering_connections, vpc_peering_connections: [connection("deleted")])
        expect(client).to receive(:describe_vpc_peering_connections).with(vpc_peering_connection_ids: [pcx_id]).and_call_original
        expect(client).not_to receive(:delete_vpc_peering_connection)
        expect { vp_test.wait_peering_cascade }.to hop("wait_client_terminated")
        expect(vp_test.fail_message).to be_nil
      end

      it "fails the test and deletes a connection that outlived the PostgreSQL destroy" do
        client.stub_responses(:describe_vpc_peering_connections, vpc_peering_connections: [connection("active")])
        expect(client).to receive(:delete_vpc_peering_connection).with(vpc_peering_connection_id: pcx_id).and_call_original
        expect { vp_test.wait_peering_cascade }.to hop("wait_client_terminated")
        expect(vp_test.fail_message).to eq "Peering connection #{pcx_id} is active after the PostgreSQL destroy"
      end

      it "tolerates a connection that changes state under its delete" do
        client.stub_responses(:describe_vpc_peering_connections, vpc_peering_connections: [connection("provisioning")])
        client.stub_responses(:delete_vpc_peering_connection, "InvalidStateTransition")
        expect(client).to receive(:delete_vpc_peering_connection).with(vpc_peering_connection_id: pcx_id).and_call_original
        expect { vp_test.wait_peering_cascade }.to hop("wait_client_terminated")
        expect(vp_test.fail_message).to eq "Peering connection #{pcx_id} is provisioning after the PostgreSQL destroy"
      end
    end
  end

  describe "#wait_client_terminated" do
    before {
      provision
      at_label("wait_client_terminated")
    }

    def instance_state(name)
      client.stub_responses(:describe_instances, reservations: [{instances: [{instance_id: client_instance, state: {name:}}]}])
    end

    it "hops to delete_customer_subnet when no client was launched" do
      expect(client).not_to receive(:describe_instances)
      expect { vp_test.wait_client_terminated }.to hop("delete_customer_subnet")
    end

    describe "with a client" do
      before { refresh_frame(vp_test, new_values: {"client_instance_id" => client_instance}) }

      it "hops to delete_customer_subnet once the client is terminated" do
        instance_state("terminated")
        expect(client).to receive(:describe_instances).with(filters: [{name: "instance-id", values: [client_instance]}]).and_call_original
        expect { vp_test.wait_client_terminated }.to hop("delete_customer_subnet")
      end

      it "hops to delete_customer_subnet once AWS no longer reports the client" do
        client.stub_responses(:describe_instances, reservations: [])
        expect { vp_test.wait_client_terminated }.to hop("delete_customer_subnet")
      end

      it "naps while the client shuts down" do
        instance_state("shutting-down")
        expect { vp_test.wait_client_terminated }.to nap(5)
      end

      it "fails the test and leaves the customer VPC to the CI cleanup when the client does not terminate in time" do
        instance_state("shutting-down")
        at_label("wait_client_terminated", expired: true)
        expect { vp_test.wait_client_terminated }.to hop("destroy_postgres")
        expect(vp_test.fail_message).to eq "Client instance #{client_instance} did not terminate within 5 minutes"
      end
    end
  end

  describe "#delete_customer_subnet" do
    before {
      provision
      at_label("delete_customer_subnet")
    }

    it "hops to delete_customer_vpc when no subnet was created" do
      expect(client).not_to receive(:delete_subnet)
      expect { vp_test.delete_customer_subnet }.to hop("delete_customer_vpc")
    end

    describe "with a subnet" do
      before { refresh_frame(vp_test, new_values: {"customer_subnet_id" => customer_subnet}) }

      it "deletes the subnet" do
        expect(client).to receive(:delete_subnet).with(subnet_id: customer_subnet).and_call_original
        expect { vp_test.delete_customer_subnet }.to hop("delete_customer_vpc")
      end

      it "hops on when the subnet is already gone" do
        client.stub_responses(:delete_subnet, "InvalidSubnetIDNotFound")
        expect { vp_test.delete_customer_subnet }.to hop("delete_customer_vpc")
      end

      it "naps while the client network interface is released" do
        client.stub_responses(:delete_subnet, "DependencyViolation")
        expect { vp_test.delete_customer_subnet }.to nap(5)
      end

      it "fails the test and leaves the customer VPC to the CI cleanup when the subnet stays in use" do
        client.stub_responses(:delete_subnet, "DependencyViolation")
        at_label("delete_customer_subnet", expired: true)
        expect { vp_test.delete_customer_subnet }.to hop("destroy_postgres")
        expect(vp_test.fail_message).to eq "Customer subnet #{customer_subnet} could not be deleted within 5 minutes"
      end
    end
  end

  describe "#delete_customer_vpc" do
    before {
      provision
      at_label("delete_customer_vpc")
    }

    it "hops to destroy_postgres when no VPC was created" do
      expect(client).not_to receive(:delete_vpc)
      expect { vp_test.delete_customer_vpc }.to hop("destroy_postgres")
    end

    describe "with a VPC" do
      before { refresh_frame(vp_test, new_values: {"customer_vpc_id" => customer_vpc}) }

      it "deletes the VPC" do
        expect(client).to receive(:delete_vpc).with(vpc_id: customer_vpc).and_call_original
        expect { vp_test.delete_customer_vpc }.to hop("destroy_postgres")
      end

      it "hops on when the VPC is already gone" do
        client.stub_responses(:delete_vpc, "InvalidVpcIDNotFound")
        expect { vp_test.delete_customer_vpc }.to hop("destroy_postgres")
      end

      it "naps while the VPC has dependencies" do
        client.stub_responses(:delete_vpc, "DependencyViolation")
        expect { vp_test.delete_customer_vpc }.to nap(5)
      end

      it "fails the test and leaves the VPC to the CI cleanup when it stays in use" do
        client.stub_responses(:delete_vpc, "DependencyViolation")
        at_label("delete_customer_vpc", expired: true)
        expect { vp_test.delete_customer_vpc }.to hop("destroy_postgres")
        expect(vp_test.fail_message).to eq "Customer VPC #{customer_vpc} could not be deleted within 5 minutes"
      end
    end
  end

  describe "#wait_resources_destroyed" do
    it "naps while the PostgreSQL resource exists" do
      provision
      expect { vp_test.wait_resources_destroyed }.to nap(5)
    end

    it "naps while the private subnet exists" do
      ps = PrivateSubnet.create(name: "subnet", project_id: vp_test.postgres_test_project_id, location_id: Location::HETZNER_FSN1_ID, net4: "10.0.0.0/26", net6: "fd00::/64")
      refresh_frame(vp_test, new_values: {"private_subnet_id" => ps.id})
      expect { vp_test.wait_resources_destroyed }.to nap(5)
    end

    it "destroys the timelines the resource left behind" do
      tl = create_postgres_timeline(location_id: Location::HETZNER_FSN1_ID)
      refresh_frame(vp_test, new_values: {"timeline_ids" => [tl.id]})
      expect { vp_test.wait_resources_destroyed }.to nap(5)
      expect(tl.destroy_set?(cached: false)).to be true
    end

    it "hops to destroy_location once everything in the location is gone" do
      expect { vp_test.wait_resources_destroyed }.to hop("destroy_location")
    end
  end

  describe "#destroy_location" do
    it "destroys the BYOC location" do
      location = Prog::LocationNexus.assemble(display_name: "vpc-peering-e2e", name: "us-west-2", ui_name: "vpc-peering-e2e", visible: true, provider: "aws", project_id: vp_test.postgres_test_project_id, byoc: true).subject
      refresh_frame(vp_test, new_values: {"location_id" => location.id})
      expect { vp_test.destroy_location }.to hop("wait_location_destroyed")
      expect(location.destroy_set?(cached: false)).to be true
    end
  end

  describe "#wait_location_destroyed" do
    it "naps while the location exists" do
      location = Location.create(display_name: "vpc-peering-e2e", name: "us-west-2", ui_name: "vpc-peering-e2e", visible: true, provider: "aws", project_id: vp_test.postgres_test_project_id, byoc: true)
      refresh_frame(vp_test, new_values: {"location_id" => location.id})
      expect { vp_test.wait_location_destroyed }.to nap(5)
    end

    it "hops to finish once the location is gone" do
      refresh_frame(vp_test, new_values: {"location_id" => Location.generate_uuid})
      expect { vp_test.wait_location_destroyed }.to hop("finish")
    end
  end
end
