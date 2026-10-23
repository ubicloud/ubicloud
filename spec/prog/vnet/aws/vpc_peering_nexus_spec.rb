# frozen_string_literal: true

RSpec.describe Prog::Vnet::Aws::VpcPeeringNexus do
  ec2_errors = Aws::EC2::Errors

  subject(:nx) { described_class.new(st) }

  let(:project) { Project.create(name: "test-prj") }
  let(:location) { Location.create(name: "us-west-2", provider: "aws", display_name: "aws-us-west-2", ui_name: "aws-us-west-2", visible: true) }
  let(:ps) {
    LocationCredentialAws.create_with_id(location, access_key: "stubbed-akid", secret_key: "stubbed-secret")
    LocationAz.create(location_id: location.id, az: "a", zone_id: "usw2-az1")
    Prog::Vnet::SubnetNexus.assemble(project.id, name: "test-ps", location_id: location.id).subject.tap {
      it.private_subnet_aws_resource.update(vpc_id: our_vpc, route_table_id: rtb)
    }
  }
  let(:st) { Prog::Vnet::VpcPeeringNexus.assemble(ps, peer_account_id: peer_account, peer_vpc_id: peer_vpc, aws: {peer_region: "us-east-1"}) }
  let(:vp) { st.subject }
  let(:aws_vp) { vp.vpc_peering_aws_resource }
  let(:client) { Aws::EC2::Client.new(stub_responses: true) }
  let(:our_vpc) { "vpc-0aaaaaaaaaaaaaaaa" }
  let(:peer_vpc) { "vpc-0bbbbbbbbbbbbbbbb" }
  let(:our_account) { "999988887777" }
  let(:peer_account) { "111122223333" }
  let(:rtb) { "rtb-0aaaaaaaaaaaaaaaa" }
  let(:pcx_id) { "pcx-0123456789abcdef0" }
  let(:id_query) { {vpc_peering_connection_ids: [pcx_id]} }
  let(:tag_query) { {filters: [{name: "tag:ubid", values: [vp.ubid]}]} }
  let(:route_query) {
    {filters: [
      {name: "route-table-id", values: [rtb]},
      {name: "route.vpc-peering-connection-id", values: [pcx_id]},
    ]}
  }
  let(:dns_on) { {vpc_peering_connection_id: pcx_id, requester_peering_connection_options: {allow_dns_resolution_from_remote_vpc: true}} }
  let(:not_routed_warning) { "Not routed: 8.8.0.0/16. Ubicloud routes only private (RFC 1918) CIDR blocks that no other VPC peering of this private subnet already routes." }
  let(:deleted_reason) { "The peering connection #{pcx_id} was deleted in AWS. Traffic no longer flows. Delete this peering and create it again to reconnect." }
  let(:dns_warning) { "Private DNS is off: turn on DNS hostnames and DNS resolution for VPC #{peer_vpc}. Until then the database hostname resolves to its public address from your VPC and traffic does not use the peering. Ubicloud retries every 15 minutes." }

  before do
    aws_credentials = Aws::Credentials.new("stubbed-akid", "stubbed-secret")
    allow(Aws::Credentials).to receive(:new).with("stubbed-akid", "stubbed-secret").and_return(aws_credentials)
    allow(Aws::EC2::Client).to receive(:new).with(credentials: aws_credentials, region: "us-west-2").and_return(client)
    st
  end

  def conn(code, id: pcx_id, requester_vpc_id: our_vpc, owner_id: our_account, cidrs: [], dns: true, message: nil, expiration_time: nil)
    {
      vpc_peering_connection_id: id,
      status: {code:, message:},
      requester_vpc_info: {vpc_id: requester_vpc_id, owner_id:, peering_options: dns.nil? ? nil : {allow_dns_resolution_from_remote_vpc: dns}},
      accepter_vpc_info: {vpc_id: peer_vpc, owner_id: peer_account, cidr_block_set: cidrs.map { {cidr_block: it} }},
      expiration_time:,
    }
  end

  def route(cidr, pcx: pcx_id, **)
    {destination_cidr_block: cidr, vpc_peering_connection_id: pcx, state: "active", **}
  end

  def stub_describe(by_id: nil, tagged: [], pair: [])
    client.stub_responses(:describe_vpc_peering_connections, lambda { |context|
      params = context.params
      if params[:vpc_peering_connection_ids]
        by_id.is_a?(Class) ? by_id.new(nil, "The vpcPeeringConnection ID '#{pcx_id}' does not exist") : {vpc_peering_connections: [by_id]}
      elsif params[:filters].first[:name] == "tag:ubid"
        {vpc_peering_connections: tagged}
      else
        {vpc_peering_connections: pair}
      end
    })
  end

  def stub_routes(cidrs, extra: [])
    client.stub_responses(:describe_route_tables, route_tables: [{route_table_id: rtb, routes: cidrs.map { route(it) } + [{destination_cidr_block: "0.0.0.0/0", gateway_id: "igw-0aaaaaaaaaaaaaaaa", state: "active"}] + extra}])
  end

  def record_connection
    aws_vp.update(peering_connection_id: pcx_id, requester_account_id: our_account)
  end

  def deadline_at
    Time.new(frame_value(nx, "deadline_at"))
  end

  describe "#start" do
    it "naps while the private subnet is created, extending its deadline" do
      refresh_frame(nx, new_values: {"deadline_target" => "wait_acceptance", "deadline_at" => st.time_string(Time.now + 60)})
      expect { nx.start }.to nap(10)
      expect(frame_value(nx, "deadline_target")).to eq "wait_acceptance"
      expect(deadline_at).to be_within(5).of(Time.now + 15 * 60)
    end

    it "hops to create_connection once the private subnet waits" do
      ps.strand.update(label: "wait")
      expect { nx.start }.to hop("create_connection")
    end

    it "destroys itself when its private subnet is being destroyed" do
      ps.incr_destroying
      expect { nx.start }.to hop("destroy")
      expect(vp.reload.destroying_set?).to be true
    end
  end

  describe "#create_connection" do
    let(:expires) { Time.now + 7 * 24 * 60 * 60 }
    let(:create_params) {
      {
        vpc_id: our_vpc,
        peer_vpc_id: peer_vpc,
        peer_owner_id: peer_account,
        peer_region: "us-east-1",
        tag_specifications: Util.aws_tag_specifications("vpc-peering-connection", "test-ps", {"ubid" => vp.ubid}),
      }
    }

    it "creates the tagged connection, records it and clears the capacity notice" do
      vp.update(state_message: "Ubicloud has reached the AWS limit")
      stub_describe
      client.stub_responses(:create_vpc_peering_connection, vpc_peering_connection: conn("initiating-request", expiration_time: expires))
      expect(client).to receive(:describe_vpc_peering_connections).with(tag_query).and_call_original
      expect(client).to receive(:create_vpc_peering_connection).with(create_params).and_call_original
      expect { nx.create_connection }.to hop("wait_connection_created")
        .and change { vp.reload.state_message }.from("Ubicloud has reached the AWS limit").to(nil)
      expect(aws_vp.reload).to have_attributes(peering_connection_id: pcx_id, requester_account_id: our_account, expires_at: be_within(1).of(expires))
    end

    it "adopts a live tagged connection without creating one" do
      stub_describe(tagged: [conn("pending-acceptance", expiration_time: expires)])
      expect(client).not_to receive(:create_vpc_peering_connection)
      expect { nx.create_connection }.to hop("wait_connection_created")
      expect(aws_vp.reload).to have_attributes(peering_connection_id: pcx_id, expires_at: be_within(1).of(expires))
    end

    it "adopts a tagged rejected connection so its rejection is reported" do
      stub_describe(tagged: [conn("rejected")])
      expect(client).not_to receive(:create_vpc_peering_connection)
      expect { nx.create_connection }.to hop("wait_connection_created")
      expect(aws_vp.reload.peering_connection_id).to eq pcx_id
    end

    it "ignores tagged deleted and deleting connections and creates one" do
      stub_describe(tagged: [conn("deleted", id: "pcx-0old0000000000001"), conn("deleting", id: "pcx-0old0000000000002")])
      client.stub_responses(:create_vpc_peering_connection, vpc_peering_connection: conn("initiating-request"))
      expect(client).to receive(:create_vpc_peering_connection).with(create_params).and_call_original
      expect { nx.create_connection }.to hop("wait_connection_created")
      expect(aws_vp.reload.peering_connection_id).to eq pcx_id
    end

    it "prefers a live tagged connection over a failed one" do
      stub_describe(tagged: [conn("failed", id: "pcx-0failed000000001"), conn("pending-acceptance")])
      expect { nx.create_connection }.to hop("wait_connection_created")
      expect(aws_vp.reload.peering_connection_id).to eq pcx_id
    end

    describe "when the VPC pair already has a connection" do
      let(:pair_filters) {
        {filters: [
          {name: "requester-vpc-info.vpc-id", values: [our_vpc, peer_vpc]},
          {name: "accepter-vpc-info.vpc-id", values: [our_vpc, peer_vpc]},
        ]}
      }
      let(:customer_request) { conn("pending-acceptance", id: "pcx-0customer000000001", requester_vpc_id: peer_vpc, owner_id: peer_account) }

      before { client.stub_responses(:create_vpc_peering_connection, ec2_errors::VpcPeeringConnectionAlreadyExists.new(nil, "A VPC peering connection between the VPCs already exists")) }

      it "adopts our live connection to the peer VPC" do
        stub_describe(pair: [conn("deleted", id: "pcx-0old0000000000001"), conn("rejected", id: "pcx-0old0000000000002"), conn("expired", id: "pcx-0old0000000000003"), conn("active", cidrs: ["10.200.0.0/16"])])
        expect(client).to receive(:describe_vpc_peering_connections).with(tag_query).and_call_original
        expect(client).to receive(:describe_vpc_peering_connections).with(pair_filters).and_call_original
        expect { nx.create_connection }.to hop("wait_connection_created")
        expect(aws_vp.reload).to have_attributes(peering_connection_id: pcx_id, expires_at: nil)
      end

      it "rejects a pending request the customer sent toward our VPC and retries" do
        stub_describe(pair: [customer_request])
        expect(client).to receive(:reject_vpc_peering_connection).with({vpc_peering_connection_id: "pcx-0customer000000001"}).and_call_original
        expect { nx.create_connection }.to nap(5)
        expect(vp.reload.state).to eq "creating"
        expect(aws_vp.reload.peering_connection_id).to be_nil
      end

      it "retries when the customer's request already left pending-acceptance" do
        stub_describe(pair: [customer_request])
        client.stub_responses(:reject_vpc_peering_connection, ec2_errors::InvalidStateTransition.new(nil, "Invalid state transition"))
        expect(client).to receive(:reject_vpc_peering_connection).with({vpc_peering_connection_id: "pcx-0customer000000001"}).and_call_original
        expect { nx.create_connection }.to nap(5)
      end

      it "fails on a live connection the customer requested toward our VPC" do
        stub_describe(pair: [conn("active", id: "pcx-0customer000000001", requester_vpc_id: peer_vpc, owner_id: peer_account)])
        expect(client).not_to receive(:reject_vpc_peering_connection)
        expect { nx.create_connection }.to hop("remove_routes")
        expect(vp.reload).to have_attributes(state: "failed", state_message: "A peering connection between VPC #{peer_vpc} and this Ubicloud VPC already exists (pcx-0customer000000001), requested from your account. Delete it in AWS, then delete this peering and create it again.")
      end

      it "naps when the connection is not visible yet" do
        stub_describe(pair: [conn("failed", id: "pcx-0old0000000000001")])
        expect { nx.create_connection }.to nap(5)
        expect(aws_vp.reload.peering_connection_id).to be_nil
      end
    end

    described_class::QUOTA_ERRORS.each do |error|
      it "retries #{error.code} on a managed location with a notice and a warning deadline capped an hour after the first hit" do
        refresh_frame(nx, new_values: {"deadline_target" => "wait_acceptance", "deadline_at" => st.time_string(Time.now + 15 * 60), "deadline_page" => true})
        stub_describe
        client.stub_responses(:create_vpc_peering_connection, error.new(nil, "You have reached the limit"))
        expect(Clog).to receive(:emit).with("VPC peering quota exceeded", {vpc_peering_quota_exceeded: {ubid: vp.ubid, location: location.ubid, error_code: error.code}}).twice.and_call_original
        expect { nx.create_connection }.to nap(300)
          .and change { vp.reload.state_message }.from(nil).to("Ubicloud has reached the AWS limit for pending peering requests in this region. The request is sent automatically when capacity frees up.")
        expect(frame_value(nx, "deadline_target")).to eq "wait_acceptance"
        expect(frame_value(nx, "deadline_page")).to eq "warning"
        first_deadline = frame_value(nx, "deadline_at")
        expect(Time.new(first_deadline)).to be_within(5).of(Time.now + 60 * 60)

        later = Time.now + 30 * 60
        expect(Time).to receive(:now).at_least(:once).and_return(later)
        expect { nx.create_connection }.to nap(300)
        expect(frame_value(nx, "deadline_at")).to eq first_deadline
      end
    end

    it "fails on a quota error in a BYOC location, where the account is the customer's" do
      location.update(project_id: project.id, byoc: true)
      stub_describe
      client.stub_responses(:create_vpc_peering_connection, ec2_errors::PendingVpcPeeringConnectionLimitExceeded.new(nil, "You have reached the limit"))
      expect(Clog).not_to receive(:emit).with("VPC peering quota exceeded", anything)
      expect { nx.create_connection }.to hop("remove_routes")
      expect(vp.reload).to have_attributes(state: "failed", state_message: "The AWS account of this location has reached its limit of VPC peering requests. Accept or delete pending requests in that account, then delete this peering and create it again. AWS said: You have reached the limit")
      expect(frame_value(nx, "deadline_target")).to eq "failed"
    end

    it "fails naming the peer region when AWS requires opting in to it" do
      stub_describe
      client.stub_responses(:create_vpc_peering_connection, ec2_errors::OptInRequired.new(nil, "You are not subscribed to this service"))
      expect { nx.create_connection }.to hop("remove_routes")
      expect(vp.reload).to have_attributes(state: "failed", state_message: "Ubicloud cannot peer with VPCs in us-east-1 yet. Delete this peering, or peer a VPC in another region. AWS said: You are not subscribed to this service")
    end

    {
      described_class::PEER_INPUT_ERRORS => "AWS refused the peering request. Check the account ID, VPC ID and region, then delete this peering and create it again.",
      described_class::PEER_LIMIT_ERRORS => "VPC vpc-0bbbbbbbbbbbbbbbb has reached its AWS limit of peering connections. Delete one of them in AWS or raise the limit, then delete this peering and create it again.",
    }.each do |errors, reason|
      errors.each do |error|
        it "fails on #{error.code} naming the peer VPC" do
          stub_describe
          client.stub_responses(:create_vpc_peering_connection, error.new(nil, "The vpc ID '#{peer_vpc}' does not exist"))
          expect { nx.create_connection }.to hop("remove_routes")
          expect(vp.reload).to have_attributes(state: "failed", state_message: "#{reason} AWS said: The vpc ID '#{peer_vpc}' does not exist")
          expect(frame_value(nx, "deadline_target")).to eq "failed"
          expect(deadline_at).to be_within(5).of(Time.now + 15 * 60)
        end

        it "propagates #{error.code} when it does not name the customer's input" do
          stub_describe
          client.stub_responses(:create_vpc_peering_connection, error.new(nil, "The vpc ID '#{our_vpc}' does not exist"))
          expect { nx.create_connection }.to raise_error(error)
          expect(vp.reload.state).to eq "creating"
        end
      end
    end

    it "fails on a peer input error naming the peer account" do
      stub_describe
      client.stub_responses(:create_vpc_peering_connection, ec2_errors::InvalidParameterValue.new(nil, "Invalid value '#{peer_account}' for peerOwnerId"))
      expect { nx.create_connection }.to hop("remove_routes")
      expect(vp.reload.state_message).to eq "AWS refused the peering request. Check the account ID, VPC ID and region, then delete this peering and create it again. AWS said: Invalid value '#{peer_account}' for peerOwnerId"
    end

    it "fails after recording when the peer account is Ubicloud's own on a managed location" do
      stub_describe
      client.stub_responses(:create_vpc_peering_connection, vpc_peering_connection: conn("initiating-request", owner_id: peer_account))
      expect { nx.create_connection }.to hop("remove_routes")
      expect(vp.reload).to have_attributes(state: "failed", state_message: "Account #{peer_account} is Ubicloud's own AWS account. Delete this peering and create it again with the ID of the AWS account that owns your VPC.")
      expect(aws_vp.reload.peering_connection_id).to eq pcx_id
    end

    it "proceeds in a BYOC location where the peer account owns the location" do
      location.update(project_id: project.id, byoc: true)
      stub_describe
      client.stub_responses(:create_vpc_peering_connection, vpc_peering_connection: conn("initiating-request", owner_id: peer_account))
      expect { nx.create_connection }.to hop("wait_connection_created")
      expect(aws_vp.reload.requester_account_id).to eq peer_account
    end

    it "propagates other errors" do
      stub_describe
      client.stub_responses(:create_vpc_peering_connection, ec2_errors::UnauthorizedOperation.new(nil, "You are not authorized to perform this operation"))
      expect { nx.create_connection }.to raise_error(ec2_errors::UnauthorizedOperation)
    end
  end

  describe "#wait_connection_created" do
    before { record_connection }

    it "naps while the connection is not visible" do
      stub_describe(by_id: ec2_errors::InvalidVpcPeeringConnectionIDNotFound)
      expect { nx.wait_connection_created }.to nap(5)
    end

    it "naps while the connection is initiating" do
      stub_describe(by_id: conn("initiating-request"))
      expect { nx.wait_connection_created }.to nap(5)
    end

    it "waits for the peer once the connection is pending acceptance" do
      stub_describe(by_id: conn("pending-acceptance"))
      expect(client).to receive(:describe_vpc_peering_connections).with(id_query).and_call_original
      expect { nx.wait_connection_created }.to hop("wait_acceptance")
        .and change { vp.reload.state }.from("creating").to("waiting_for_peer")
    end
  end

  describe "#wait_acceptance" do
    before do
      record_connection
      vp.update(state: "waiting_for_peer")
    end

    it "records the expiry and polls every 30 seconds in the first hour" do
      expires = Time.now + 6 * 24 * 60 * 60
      stub_describe(by_id: conn("pending-acceptance", expiration_time: expires))
      expect { nx.wait_acceptance }.to nap(30)
      expect(aws_vp.reload.expires_at).to be_within(1).of(expires)
    end

    it "polls every 5 minutes after the first hour" do
      vp.update(created_at: Time.now - 2 * 60 * 60)
      stub_describe(by_id: conn("pending-acceptance"))
      expect { nx.wait_acceptance }.to nap(300)
    end

    it "naps 5 without a deadline while initiating-request" do
      stub_describe(by_id: conn("initiating-request"))
      expect { nx.wait_acceptance }.to nap(5)
      expect(frame_value(nx, "deadline_target")).to be_nil
    end

    it "naps 5 under the wait deadline while provisioning" do
      stub_describe(by_id: conn("provisioning"))
      expect { nx.wait_acceptance }.to nap(5)
      expect(frame_value(nx, "deadline_target")).to eq "wait"
      expect(deadline_at).to be_within(5).of(Time.now + 15 * 60)
    end

    it "keeps the first wait deadline on later provisioning passes" do
      first_deadline = st.time_string(Time.now + 60)
      refresh_frame(nx, new_values: {"deadline_target" => "wait", "deadline_at" => first_deadline})
      stub_describe(by_id: conn("provisioning"))
      expect { nx.wait_acceptance }.to nap(5)
      expect(frame_value(nx, "deadline_at")).to eq first_deadline
    end

    it "claims the sorted CIDRs of an active connection and hops to configure under a wait deadline" do
      stub_describe(by_id: conn("active", cidrs: ["10.201.0.0/16", "10.200.0.0/16"]))
      expect { nx.wait_acceptance }.to hop("configure")
        .and change { vp.reload.state }.from("waiting_for_peer").to("configuring")
      expect(vp.peer_cidrs.map(&:to_s)).to eq ["10.200.0.0/16", "10.201.0.0/16"]
      expect(frame_value(nx, "deadline_target")).to eq "wait"
      expect(deadline_at).to be_within(5).of(Time.now + 15 * 60)
    end

    it "naps under the wait deadline while an active connection shows no CIDR blocks yet" do
      stub_describe(by_id: conn("active"))
      expect { nx.wait_acceptance }.to nap(5)
      expect(vp.reload.state).to eq "waiting_for_peer"
      expect(frame_value(nx, "deadline_target")).to eq "wait"
    end

    it "does not claim a CIDR overlapping a sibling's claim, and ignores siblings without one" do
      VpcPeering.create(private_subnet_id: ps.id, peer_account_id: peer_account, peer_vpc_id: "vpc-0cccccccccccccccc", state: "active", peer_cidrs: Sequel.pg_array(["10.200.0.0/16"], :cidr))
      VpcPeering.create(private_subnet_id: ps.id, peer_account_id: peer_account, peer_vpc_id: "vpc-0dddddddddddddddd")
      stub_describe(by_id: conn("active", cidrs: ["10.200.5.0/24", "10.201.0.0/16"]))
      expect { nx.wait_acceptance }.to hop("configure")
      expect(vp.reload.peer_cidrs.map(&:to_s)).to eq ["10.201.0.0/16"]
    end

    it "sees a sibling's claim committed while it waited for the subnet lock" do
      stub_describe(by_id: conn("active", cidrs: ["10.200.5.0/24", "10.201.0.0/16"]))
      expect(nx.private_subnet).to receive(:lock!).with(:no_key_update).and_wrap_original do |original, *args|
        VpcPeering.create(private_subnet_id: ps.id, peer_account_id: peer_account, peer_vpc_id: "vpc-0cccccccccccccccc", state: "active", peer_cidrs: Sequel.pg_array(["10.200.0.0/16"], :cidr))
        original.call(*args)
      end
      expect { nx.wait_acceptance }.to hop("configure")
      expect(vp.reload.peer_cidrs.map(&:to_s)).to eq ["10.201.0.0/16"]
    end

    it "claims only CIDRs inside a private range" do
      stub_describe(by_id: conn("active", cidrs: ["8.8.0.0/16", "10.200.0.0/16", "192.168.0.0/15"]))
      expect { nx.wait_acceptance }.to hop("configure")
      expect(vp.reload.peer_cidrs.map(&:to_s)).to eq ["10.200.0.0/16"]
    end

    it "does not claim a CIDR overlapping a private control plane range" do
      expect(Config).to receive(:control_plane_outbound_cidrs).and_return(["0.0.0.0/0", "192.168.10.0/24", "::/0"])
      stub_describe(by_id: conn("active", cidrs: ["192.168.0.0/16", "10.200.0.0/16"]))
      expect { nx.wait_acceptance }.to hop("configure")
      expect(vp.reload.peer_cidrs.map(&:to_s)).to eq ["10.200.0.0/16"]
    end

    it "claims everything private under the default control plane ranges" do
      expect(Config).to receive(:control_plane_outbound_cidrs).and_return(["0.0.0.0/0", "::/0"])
      stub_describe(by_id: conn("active", cidrs: ["192.168.0.0/16", "172.16.0.0/12", "10.0.0.0/8"]))
      expect { nx.wait_acceptance }.to hop("configure")
      expect(vp.reload.peer_cidrs.map(&:to_s)).to eq ["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16"]
    end

    it "fails when no CIDR can be routed" do
      VpcPeering.create(private_subnet_id: ps.id, peer_account_id: peer_account, peer_vpc_id: "vpc-0cccccccccccccccc", state: "active", peer_cidrs: Sequel.pg_array(["10.0.0.0/8"], :cidr))
      stub_describe(by_id: conn("active", cidrs: ["8.8.0.0/16", "10.200.0.0/16"]))
      expect { nx.wait_acceptance }.to hop("remove_routes")
      expect(vp.reload).to have_attributes(state: "failed", peer_cidrs: [], state_message: "None of the CIDR blocks of VPC #{peer_vpc} (10.200.0.0/16, 8.8.0.0/16) can be routed. Ubicloud routes only private (RFC 1918) CIDR blocks that no other VPC peering of this private subnet already routes. Delete this peering, then create it again once no other peering routes those blocks, or peer a VPC with other private CIDR blocks.")
      expect(frame_value(nx, "deadline_target")).to eq "failed"
    end

    it "keeps polling when the connection is not found before it expires" do
      aws_vp.update(expires_at: Time.now + 60 * 60)
      stub_describe(by_id: ec2_errors::InvalidVpcPeeringConnectionIDNotFound)
      expect { nx.wait_acceptance }.to nap(30)
      expect(vp.reload.state).to eq "waiting_for_peer"
    end

    it "fails when the connection is not found after it expired" do
      aws_vp.update(expires_at: Time.now - 60)
      stub_describe(by_id: ec2_errors::InvalidVpcPeeringConnectionIDNotFound)
      expect { nx.wait_acceptance }.to hop("remove_routes")
      expect(vp.reload).to have_attributes(state: "failed", state_message: "The peering connection #{pcx_id} no longer exists in AWS. Delete this peering and create it again.")
    end

    it "fails when the connection is not found and its expiry is unknown" do
      stub_describe(by_id: ec2_errors::InvalidVpcPeeringConnectionIDNotFound)
      expect { nx.wait_acceptance }.to hop("remove_routes")
      expect(vp.reload.state).to eq "failed"
    end

    it "follows a live tagged connection when the recorded one failed" do
      refresh_frame(nx, new_values: {"deadline_target" => "wait", "deadline_at" => st.time_string(Time.now + 60)})
      stub_describe(by_id: conn("failed", message: "Overlapping CIDR"), tagged: [conn("failed", message: "Overlapping CIDR"), conn("pending-acceptance", id: "pcx-0second000000001")])
      expect(client).to receive(:describe_vpc_peering_connections).with(id_query).and_call_original
      expect(client).to receive(:describe_vpc_peering_connections).with(tag_query).and_call_original
      expect { nx.wait_acceptance }.to nap(5)
      expect(aws_vp.reload.peering_connection_id).to eq "pcx-0second000000001"
      expect(vp.reload.state).to eq "waiting_for_peer"
      expect(frame_value(nx, "deadline_target")).to be_nil
    end

    it "fails with AWS's reason and our CIDR for a failed connection" do
      stub_describe(by_id: conn("failed", message: "Overlapping CIDR"), tagged: [conn("failed", message: "Overlapping CIDR")])
      expect { nx.wait_acceptance }.to hop("remove_routes")
      expect(vp.reload).to have_attributes(state: "failed", state_message: "AWS could not establish the peering connection (Overlapping CIDR). Check the account ID, VPC ID and region, and that no CIDR block of your VPC overlaps #{ps.net4}. Delete this peering and create it again.")
      expect(frame_value(nx, "deadline_target")).to eq "failed"
    end

    it "reports the rejection instead of following a final tagged duplicate" do
      stub_describe(by_id: conn("rejected"), tagged: [conn("failed", id: "pcx-0dup0000000000001"), conn("rejected")])
      expect { nx.wait_acceptance }.to hop("remove_routes")
      expect(vp.reload.state_message).to eq "The peering request was rejected in AWS account 111122223333. Delete this peering and create it again."
      expect(aws_vp.reload.peering_connection_id).to eq pcx_id
    end

    it "fails when a lagging tagged read still shows the recorded connection live" do
      stub_describe(by_id: conn("rejected"), tagged: [conn("pending-acceptance")])
      expect { nx.wait_acceptance }.to hop("remove_routes")
      expect(vp.reload.state_message).to eq "The peering request was rejected in AWS account 111122223333. Delete this peering and create it again."
    end

    {
      "rejected" => "The peering request was rejected in AWS account 111122223333. Delete this peering and create it again.",
      "expired" => "The peering request expired before it was accepted. Delete this peering and create it again.",
      "deleted" => "The peering request was deleted in AWS before it was accepted. Delete this peering and create it again.",
    }.each do |code, reason|
      it "fails with the reason for a #{code} connection" do
        stub_describe(by_id: conn(code), tagged: [conn(code)])
        expect { nx.wait_acceptance }.to hop("remove_routes")
        expect(vp.reload).to have_attributes(state: "failed", state_message: reason)
      end
    end
  end

  describe "#configure" do
    before do
      record_connection
      vp.update(state: "configuring", peer_cidrs: Sequel.pg_array(["10.200.0.0/16"], :cidr))
      refresh_frame(nx, new_values: {"deadline_target" => "wait", "deadline_at" => st.time_string(Time.now + 15 * 60)})
    end

    it "fails when the connection was deleted" do
      stub_describe(by_id: conn("deleted"))
      expect { nx.configure }.to hop("remove_routes")
      expect(vp.reload).to have_attributes(state: "failed", state_message: deleted_reason)
      expect(frame_value(nx, "deadline_target")).to eq "failed"
    end

    it "fails when the connection is not found" do
      stub_describe(by_id: ec2_errors::InvalidVpcPeeringConnectionIDNotFound)
      expect { nx.configure }.to hop("remove_routes")
      expect(vp.reload.state_message).to eq deleted_reason
    end

    %w[pending-acceptance provisioning].each do |code|
      it "naps in place under the wait deadline while the connection reads #{code}" do
        stub_describe(by_id: conn(code))
        expect(client).not_to receive(:describe_route_tables)
        expect { nx.configure }.to nap(5)
        expect(frame_value(nx, "deadline_target")).to eq "wait"
      end
    end

    it "creates missing routes and deletes extra ones, then naps to verify before DNS" do
      stub_describe(by_id: conn("active", cidrs: ["10.200.0.0/16"], dns: false))
      stub_routes(["10.199.0.0/16"])
      expect(client).to receive(:describe_route_tables).with(route_query).and_call_original
      expect(client).to receive(:delete_route).with({route_table_id: rtb, destination_cidr_block: "10.199.0.0/16"}).and_call_original
      expect(client).to receive(:create_route).with({route_table_id: rtb, destination_cidr_block: "10.200.0.0/16", vpc_peering_connection_id: pcx_id}).and_call_original
      expect(client).not_to receive(:modify_vpc_peering_connection_options)
      expect { nx.configure }.to nap(5)
      expect(vp.reload.state).to eq "configuring"
    end

    it "tolerates an extra route that is already gone" do
      stub_describe(by_id: conn("active", cidrs: ["10.200.0.0/16"]))
      stub_routes(["10.199.0.0/16", "10.200.0.0/16"])
      client.stub_responses(:delete_route, ec2_errors::InvalidRouteNotFound.new(nil, "no route with destination-cidr-block 10.199.0.0/16"))
      expect(client).to receive(:delete_route).with({route_table_id: rtb, destination_cidr_block: "10.199.0.0/16"}).and_call_original
      expect(client).not_to receive(:create_route)
      expect { nx.configure }.to nap(5)
    end

    it "sets active and hops to wait once routes converged and DNS is on" do
      stub_describe(by_id: conn("active", cidrs: ["10.200.0.0/16"]))
      stub_routes(["10.200.0.0/16"])
      expect(client).not_to receive(:create_route)
      expect(client).not_to receive(:delete_route)
      expect(client).not_to receive(:modify_vpc_peering_connection_options)
      expect { nx.configure }.to hop("wait")
        .and change { vp.reload.state }.from("configuring").to("active")
      expect(vp.state_message).to be_nil
    end

    it "turns on DNS resolution when it is off" do
      stub_describe(by_id: conn("active", cidrs: ["10.200.0.0/16"], dns: false))
      stub_routes(["10.200.0.0/16"])
      expect(client).to receive(:modify_vpc_peering_connection_options).with(dns_on).and_call_original
      expect { nx.configure }.to hop("wait")
      expect(vp.reload).to have_attributes(state: "active", state_message: nil)
    end

    it "turns on DNS resolution when AWS omits the peering options" do
      stub_describe(by_id: conn("active", cidrs: ["10.200.0.0/16"], dns: nil))
      stub_routes(["10.200.0.0/16"])
      expect(client).to receive(:modify_vpc_peering_connection_options).with(dns_on).and_call_original
      expect { nx.configure }.to hop("wait")
    end

    it "becomes active with both warnings when a CIDR is unrouted and the peer VPC has DNS hostnames off" do
      stub_describe(by_id: conn("active", cidrs: ["10.200.0.0/16", "8.8.0.0/16"], dns: false))
      stub_routes(["10.200.0.0/16"])
      client.stub_responses(:modify_vpc_peering_connection_options, ec2_errors::InvalidVpcPeeringConnectionStateDnsHostnamesDisabled.new(nil, "DNS hostnames disabled"))
      expect { nx.configure }.to hop("wait")
      expect(vp.reload).to have_attributes(state: "active", state_message: "#{not_routed_warning} #{dns_warning}")
    end

    it "warns about CIDR blocks it does not route" do
      stub_describe(by_id: conn("active", cidrs: ["10.200.0.0/16", "8.8.0.0/16"]))
      stub_routes(["10.200.0.0/16"])
      expect { nx.configure }.to hop("wait")
      expect(vp.reload.state_message).to eq not_routed_warning
    end

    describe "when a route to the CIDR already exists" do
      let(:by_destination) {
        {filters: [
          {name: "route-table-id", values: [rtb]},
          {name: "route.destination-cidr-block", values: ["10.200.0.0/16"]},
        ]}
      }

      before do
        stub_describe(by_id: conn("active", cidrs: ["10.200.0.0/16"]))
        client.stub_responses(:create_route, ec2_errors::RouteAlreadyExists.new(nil, "The route identified by 10.200.0.0/16 already exists."))
      end

      def stub_existing(routes)
        client.stub_responses(:describe_route_tables, lambda { |context|
          if context.params[:filters].last[:name] == "route.destination-cidr-block"
            {route_tables: [{route_table_id: rtb, routes: routes + [{destination_cidr_block: "0.0.0.0/0", gateway_id: "igw-0aaaaaaaaaaaaaaaa", state: "active"}]}]}
          else
            {route_tables: []}
          end
        })
      end

      it "naps before the remaining routes when the route is not visible yet" do
        vp.update(peer_cidrs: Sequel.pg_array(["10.200.0.0/16", "10.201.0.0/16"], :cidr))
        stub_existing([])
        expect(client).to receive(:describe_route_tables).with(route_query).and_call_original
        expect(client).to receive(:create_route).once.with({route_table_id: rtb, destination_cidr_block: "10.200.0.0/16", vpc_peering_connection_id: pcx_id}).and_call_original
        expect(client).to receive(:describe_route_tables).with(by_destination).and_call_original
        expect { nx.configure }.to nap(5)
      end

      it "keeps a route that already targets our connection and naps to verify" do
        stub_existing([route("10.200.0.0/16")])
        expect(client).not_to receive(:replace_route)
        expect { nx.configure }.to nap(5)
      end

      it "replaces a blackhole route" do
        stub_existing([route("10.200.0.0/16", pcx: "pcx-0gone00000000001", state: "blackhole")])
        expect(client).to receive(:replace_route).with({route_table_id: rtb, destination_cidr_block: "10.200.0.0/16", vpc_peering_connection_id: pcx_id}).and_call_original
        expect { nx.configure }.to nap(5)
      end

      it "raises on a live route to another peering connection" do
        stub_existing([route("10.200.0.0/16", pcx: "pcx-0other0000000001")])
        expect { nx.configure }.to raise_error(RuntimeError, "Route to 10.200.0.0/16 in #{rtb} already targets pcx-0other0000000001")
      end

      it "raises on a live route to a gateway" do
        stub_existing([{destination_cidr_block: "10.200.0.0/16", gateway_id: "vgw-0aaaaaaaaaaaaaaaa", state: "active"}])
        expect { nx.configure }.to raise_error(RuntimeError, "Route to 10.200.0.0/16 in #{rtb} already targets vgw-0aaaaaaaaaaaaaaaa")
      end
    end
  end

  describe "#wait" do
    before do
      record_connection
      vp.update(state: "active", peer_cidrs: Sequel.pg_array(["10.200.0.0/16"], :cidr))
    end

    it "naps 15 minutes in the steady state with one connection and one route table read" do
      stub_describe(by_id: conn("active", cidrs: ["10.200.0.0/16"]))
      stub_routes(["10.200.0.0/16"])
      expect(client).to receive(:describe_vpc_peering_connections).once.with(id_query).and_call_original
      expect(client).to receive(:describe_route_tables).once.with(route_query).and_call_original
      expect(client).not_to receive(:modify_vpc_peering_connection_options)
      expect(client).not_to receive(:create_route)
      expect(client).not_to receive(:delete_route)
      expect { nx.wait }.to nap(15 * 60)
      expect(vp.reload).to have_attributes(state: "active", state_message: nil)
    end

    it "naps 5 while the connection does not read active" do
      stub_describe(by_id: conn("provisioning"))
      expect(client).not_to receive(:describe_route_tables)
      expect { nx.wait }.to nap(5)
      expect(vp.reload.state).to eq "active"
    end

    it "fails when the connection is not found" do
      stub_describe(by_id: ec2_errors::InvalidVpcPeeringConnectionIDNotFound)
      expect { nx.wait }.to hop("remove_routes")
      expect(vp.reload).to have_attributes(state: "failed", state_message: deleted_reason)
    end

    %w[deleted deleting].each do |code|
      it "fails when the connection is #{code}" do
        stub_describe(by_id: conn(code))
        expect { nx.wait }.to hop("remove_routes")
        expect(vp.reload).to have_attributes(state: "failed", state_message: deleted_reason)
      end
    end

    it "hops to configure under a wait deadline when not active" do
      vp.update(state: "configuring")
      stub_describe(by_id: conn("active", cidrs: ["10.200.0.0/16"]))
      expect(client).not_to receive(:describe_route_tables)
      expect { nx.wait }.to hop("configure")
      expect(frame_value(nx, "deadline_target")).to eq "wait"
      expect(deadline_at).to be_within(5).of(Time.now + 15 * 60)
    end

    it "claims a new peer CIDR and marks configuring without touching DNS" do
      stub_describe(by_id: conn("active", cidrs: ["10.200.0.0/16", "10.201.0.0/16"], dns: false))
      stub_routes(["10.200.0.0/16"])
      expect(client).not_to receive(:modify_vpc_peering_connection_options)
      expect { nx.wait }.to nap(5)
        .and change { vp.reload.state }.from("active").to("configuring")
      expect(vp.peer_cidrs.map(&:to_s)).to eq ["10.200.0.0/16", "10.201.0.0/16"]
    end

    it "releases a removed peer CIDR and marks configuring" do
      vp.update(peer_cidrs: Sequel.pg_array(["10.200.0.0/16", "10.201.0.0/16"], :cidr))
      stub_describe(by_id: conn("active", cidrs: ["10.200.0.0/16"]))
      stub_routes(["10.200.0.0/16", "10.201.0.0/16"])
      expect { nx.wait }.to nap(5)
        .and change { vp.reload.state }.from("active").to("configuring")
      expect(vp.peer_cidrs.map(&:to_s)).to eq ["10.200.0.0/16"]
    end

    it "marks configuring when a route to the connection is missing" do
      stub_describe(by_id: conn("active", cidrs: ["10.200.0.0/16"]))
      stub_routes([])
      expect { nx.wait }.to nap(5)
        .and change { vp.reload.state }.from("active").to("configuring")
    end

    it "marks configuring when an extra route targets the connection" do
      stub_describe(by_id: conn("active", cidrs: ["10.200.0.0/16"]))
      stub_routes(["10.200.0.0/16", "10.199.0.0/16"])
      expect { nx.wait }.to nap(5)
        .and change { vp.reload.state }.from("active").to("configuring")
    end

    it "ignores IPv6 routes to the connection when comparing" do
      stub_describe(by_id: conn("active", cidrs: ["10.200.0.0/16"]))
      stub_routes(["10.200.0.0/16"], extra: [{destination_ipv_6_cidr_block: "2600:1f14::/56", vpc_peering_connection_id: pcx_id, state: "active"}])
      expect { nx.wait }.to nap(15 * 60)
    end

    it "keeps an unresolved conflict and a public CIDR unrouted without marking configuring" do
      VpcPeering.create(private_subnet_id: ps.id, peer_account_id: peer_account, peer_vpc_id: "vpc-0cccccccccccccccc", state: "active", peer_cidrs: Sequel.pg_array(["10.201.0.0/16"], :cidr))
      stub_describe(by_id: conn("active", cidrs: ["10.200.0.0/16", "10.201.0.0/24", "8.8.0.0/16"]))
      stub_routes(["10.200.0.0/16"])
      expect { nx.wait }.to nap(15 * 60)
      expect(vp.reload).to have_attributes(state: "active", state_message: "Not routed: 10.201.0.0/24, 8.8.0.0/16. Ubicloud routes only private (RFC 1918) CIDR blocks that no other VPC peering of this private subnet already routes.")
      expect(vp.peer_cidrs.map(&:to_s)).to eq ["10.200.0.0/16"]
    end

    it "claims a CIDR once the sibling that held it is deleted" do
      sibling = VpcPeering.create(private_subnet_id: ps.id, peer_account_id: peer_account, peer_vpc_id: "vpc-0cccccccccccccccc", state: "active", peer_cidrs: Sequel.pg_array(["10.201.0.0/16"], :cidr))
      stub_describe(by_id: conn("active", cidrs: ["10.200.0.0/16", "10.201.0.0/16"]))
      stub_routes(["10.200.0.0/16"])
      expect { nx.wait }.to nap(15 * 60)

      sibling.destroy
      expect { nx.wait }.to nap(5)
        .and change { vp.reload.state }.from("active").to("configuring")
      expect(vp.peer_cidrs.map(&:to_s)).to eq ["10.200.0.0/16", "10.201.0.0/16"]
    end

    it "keeps the claim when the connection shows no CIDR blocks" do
      stub_describe(by_id: conn("active"))
      stub_routes(["10.200.0.0/16"])
      expect { nx.wait }.to nap(15 * 60)
      expect(vp.reload.peer_cidrs.map(&:to_s)).to eq ["10.200.0.0/16"]
    end

    it "retries DNS resolution in place after the route checks" do
      vp.update(state_message: dns_warning)
      stub_describe(by_id: conn("active", cidrs: ["10.200.0.0/16"], dns: false))
      stub_routes(["10.200.0.0/16"])
      client.stub_responses(:modify_vpc_peering_connection_options, ec2_errors::InvalidVpcPeeringConnectionStateDnsHostnamesDisabled.new(nil, "DNS hostnames disabled"))
      expect(client).to receive(:modify_vpc_peering_connection_options).with(dns_on).and_call_original
      expect { nx.wait }.to nap(15 * 60)
      expect(vp.reload).to have_attributes(state: "active", state_message: dns_warning)
    end

    it "clears the DNS warning once DNS resolution is on" do
      vp.update(state_message: dns_warning)
      stub_describe(by_id: conn("active", cidrs: ["10.200.0.0/16"], dns: false))
      stub_routes(["10.200.0.0/16"])
      expect(client).to receive(:modify_vpc_peering_connection_options).with(dns_on).and_call_original
      expect { nx.wait }.to nap(15 * 60)
        .and change { vp.reload.state_message }.from(dns_warning).to(nil)
    end

    it "propagates other DNS errors after the claim checks" do
      stub_describe(by_id: conn("active", cidrs: ["10.200.0.0/16"], dns: false))
      stub_routes(["10.200.0.0/16"])
      client.stub_responses(:modify_vpc_peering_connection_options, ec2_errors::UnauthorizedOperation.new(nil, "You are not authorized to perform this operation"))
      expect(client).to receive(:describe_route_tables).once.with(route_query).and_call_original
      expect { nx.wait }.to raise_error(ec2_errors::UnauthorizedOperation)
    end
  end

  describe "#destroy" do
    it "clears destroy, registers a deadline and hops to remove_routes" do
      vp.incr_destroy
      expect { nx.destroy }.to hop("remove_routes")
      expect(vp.reload.destroy_set?).to be false
      expect(nx.strand.stack.first).to include("deadline_target" => nil)
      expect(deadline_at).to be_within(5).of(Time.now + 15 * 60)
    end
  end

  describe "#remove_routes" do
    it "deletes every IPv4, IPv6 and prefix list route that targets the connection and releases the claim" do
      record_connection
      vp.update(peer_cidrs: Sequel.pg_array(["10.200.0.0/16"], :cidr))
      stub_routes(["10.200.0.0/16"], extra: [
        {destination_ipv_6_cidr_block: "2600:1f14::/56", vpc_peering_connection_id: pcx_id, state: "active"},
        {destination_prefix_list_id: "pl-0aaaaaaaaaaaaaaaa", vpc_peering_connection_id: pcx_id, state: "active"},
      ])
      client.stub_responses(:delete_route, [{}, ec2_errors::InvalidRouteNotFound.new(nil, "no route"), {}])
      expect(client).to receive(:describe_route_tables).with(route_query).and_call_original
      expect(client).to receive(:delete_route).with({route_table_id: rtb, destination_cidr_block: "10.200.0.0/16"}).and_call_original
      expect(client).to receive(:delete_route).with({route_table_id: rtb, destination_ipv_6_cidr_block: "2600:1f14::/56"}).and_call_original
      expect(client).to receive(:delete_route).with({route_table_id: rtb, destination_prefix_list_id: "pl-0aaaaaaaaaaaaaaaa"}).and_call_original
      expect { nx.remove_routes }.to hop("delete_connection")
      expect(vp.reload.peer_cidrs).to eq []
    end

    it "makes no AWS call when no connection was recorded" do
      expect(client).not_to receive(:describe_route_tables)
      expect { nx.remove_routes }.to hop("delete_connection")
    end
  end

  describe "#delete_connection" do
    before { record_connection }

    it "deletes live tagged connections and the untagged recorded one, skipping final ones, and naps" do
      stub_describe(by_id: conn("active"), tagged: [conn("pending-acceptance", id: "pcx-0tagged000000001"), conn("active", id: "pcx-0tagged000000002"), conn("failed", id: "pcx-0tagged000000003")])
      expect(client).to receive(:describe_vpc_peering_connections).with(tag_query).and_call_original
      expect(client).to receive(:describe_vpc_peering_connections).with(id_query).and_call_original
      ["pcx-0tagged000000001", "pcx-0tagged000000002", pcx_id].each do
        expect(client).to receive(:delete_vpc_peering_connection).with({vpc_peering_connection_id: it}).and_call_original
      end
      expect { nx.delete_connection }.to nap(5)
    end

    it "tolerates connections that are already gone or changing state" do
      stub_describe(tagged: [conn("active"), conn("pending-acceptance", id: "pcx-0tagged000000001")])
      client.stub_responses(:delete_vpc_peering_connection, [ec2_errors::InvalidVpcPeeringConnectionIDNotFound.new(nil, "not found"), ec2_errors::InvalidStateTransition.new(nil, "Invalid state transition")])
      [pcx_id, "pcx-0tagged000000001"].each do
        expect(client).to receive(:delete_vpc_peering_connection).with({vpc_peering_connection_id: it}).and_call_original
      end
      expect(client).to receive(:describe_vpc_peering_connections).once.with(tag_query).and_call_original
      expect { nx.delete_connection }.to nap(5)
    end

    it "naps without deleting while connections are deleting or provisioning" do
      stub_describe(tagged: [conn("deleting"), conn("provisioning", id: "pcx-0tagged000000001")])
      expect(client).not_to receive(:delete_vpc_peering_connection)
      expect { nx.delete_connection }.to nap(5)
    end

    it "hops to failed when nothing live remains and the peering is not being destroyed" do
      stub_describe(by_id: ec2_errors::InvalidVpcPeeringConnectionIDNotFound, tagged: [conn("deleted", id: "pcx-0tagged000000001"), conn("rejected", id: "pcx-0tagged000000002"), conn("expired", id: "pcx-0tagged000000003")])
      expect(client).not_to receive(:delete_vpc_peering_connection)
      expect { nx.delete_connection }.to hop("failed")
    end

    it "hops to finish when the peering is being destroyed" do
      aws_vp.update(peering_connection_id: nil, requester_account_id: nil)
      vp.incr_destroying
      stub_describe
      expect(client).to receive(:describe_vpc_peering_connections).once.with(tag_query).and_call_original
      expect { nx.delete_connection }.to hop("finish")
    end
  end

  describe "#finish" do
    it "destroys the peering and its AWS row and pops" do
      expect { nx.finish }.to exit({"msg" => "vpc peering destroyed"})
      expect(VpcPeering[vp.id]).to be_nil
      expect(VpcPeeringAwsResource[vp.id]).to be_nil
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
end
