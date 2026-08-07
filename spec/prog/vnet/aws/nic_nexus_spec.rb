# frozen_string_literal: true

RSpec.describe Prog::Vnet::Aws::NicNexus do
  subject(:nx) {
    described_class.new(st)
  }

  let(:st) { nic.strand }

  let(:nic) {
    prj = Project.create(name: "test-prj")
    loc = Location.create(name: "us-west-2", provider: "aws", project_id: prj.id, display_name: "aws-us-west-2", ui_name: "AWS US East 1", visible: true)
    LocationCredentialAws.create_with_id(loc.id, access_key: "test-access-key", secret_key: "test-secret-key")
    az_a = LocationAz.create(location_id: loc.id, az: "a", zone_id: "usw2-az1")
    ps = Prog::Vnet::SubnetNexus.assemble(prj.id, name: "test-ps", location_id: loc.id).subject
    ps.strand.update(label: "wait")
    # SubnetNexus.assemble creates PrivateSubnetAwsResource and AwsSubnet records
    # Update them with the test values
    ps.private_subnet_aws_resource.update(user_security_group_id: "sg-0123456789abcdefg", mgmt_security_group_id: "sg-0123456789abcdefg", vpc_id: "vpc-0123456789abcdefg")
    aws_subnet = AwsSubnet.where(private_subnet_aws_resource_id: ps.private_subnet_aws_resource.id, location_aws_az_id: az_a.id).first
    aws_subnet.update(subnet_id: "subnet-0123456789abcdefg", ipv6_cidr: "2600:1f14:1000::/64")
    nic = Prog::Vnet::NicNexus.assemble(ps.id, name: "test-nic").subject
    NicAwsResource.create_with_id(nic.id, subnet_id: "subnet-0123456789abcdefg", subnet_az: "us-west-2a")
    nic
  }

  let(:client) {
    Aws::EC2::Client.new(stub_responses: true)
  }

  before do
    allow(Aws::EC2::Client).to receive(:new).with(credentials: anything, region: "us-west-2").and_return(client)
  end

  describe "#start" do
    it "creates a nic aws resource that uses an eip by default" do
      NicAwsResource[nic.id].destroy
      expect { nx.start }.to hop("create_subnet")
      expect(NicAwsResource[nic.id]).to have_attributes(use_eip: true)
    end

    it "creates a nic aws resource without an eip when the frame says so" do
      NicAwsResource[nic.id].destroy
      refresh_frame(nx, new_values: {"use_eip" => false})
      expect { nx.start }.to hop("create_subnet")
      expect(NicAwsResource[nic.id]).to have_attributes(use_eip: false)
    end
  end

  describe "#create_subnet" do
    it "naps if subnet is not ready" do
      nic.private_subnet.strand.update(label: "create_aws_vpc")
      expect { nx.create_subnet }.to nap(2)
    end

    it "uses aws_subnet_id from frame and hops to create_network_interface" do
      aws_subnet = AwsSubnet.where(private_subnet_aws_resource_id: nic.private_subnet.private_subnet_aws_resource.id).first
      refresh_frame(nx, new_values: {"aws_subnet_id" => aws_subnet.id})
      expect { nx.create_subnet }.to hop("create_network_interface")
      expect(nic.nic_aws_resource.reload).to have_attributes(subnet_id: aws_subnet.subnet_id, subnet_az: aws_subnet.az_suffix, aws_subnet_id: aws_subnet.id)
    end

    it "fails if aws_subnet_id from frame is not found" do
      refresh_frame(nx, new_values: {"aws_subnet_id" => "00000000-0000-0000-0000-000000000000"})
      expect { nx.create_subnet }.to raise_error("No available AWS subnet found")
    end

    it "hops to wait without an eip, skipping network interface and EIP creation" do
      aws_subnet = AwsSubnet.where(private_subnet_aws_resource_id: nic.private_subnet.private_subnet_aws_resource.id).first
      refresh_frame(nx, new_values: {"aws_subnet_id" => aws_subnet.id})
      nic.nic_aws_resource.update(use_eip: false)
      expect { nx.create_subnet }.to hop("wait")
    end

    it "creates the per-NIC security group before waiting for a no-eip nic" do
      aws_subnet = AwsSubnet.where(private_subnet_aws_resource_id: nic.private_subnet.private_subnet_aws_resource.id).first
      refresh_frame(nx, new_values: {"aws_subnet_id" => aws_subnet.id, "use_per_nic_security_group" => true})
      nic.nic_aws_resource.update(use_eip: false)
      expect { nx.create_subnet }.to hop("create_security_group")
    end
  end

  describe "#create_security_group" do
    let(:ownership_tags) { {"PrivateSubnet" => nic.private_subnet.ubid, "Nic" => nic.ubid} }

    before do
      client.stub_responses(:authorize_security_group_ingress)
    end

    it "creates and persists a tagged per-NIC group before waiting for a no-eip nic" do
      nic.nic_aws_resource.update(use_eip: false)
      client.stub_responses(:create_security_group, group_id: "sg-per-nic")
      expect(client).to receive(:create_security_group).with({
        group_name: "aws-us-west-2-#{nic.ubid}-user",
        description: "User security group for aws-us-west-2-#{nic.ubid}",
        vpc_id: "vpc-0123456789abcdefg",
        tag_specifications: Util.aws_tag_specifications("security-group", nic.name, ownership_tags),
      }).and_call_original

      expect { nx.create_security_group }.to hop("wait")
      expect(nic.nic_aws_resource.reload.security_group_id).to eq("sg-per-nic")
      expected_ingress = Config.control_plane_outbound_cidrs.map do |cidr|
        ranges = cidr.include?(":") ? {ipv_6_ranges: [{cidr_ipv_6: cidr}]} : {ip_ranges: [{cidr_ip: cidr}]}
        {group_id: "sg-per-nic", ip_permissions: [{ip_protocol: "tcp", from_port: 22, to_port: 22, **ranges}]}
      end
      actual_ingress = client.api_requests.filter_map { it[:params] if it[:operation_name] == :authorize_security_group_ingress }
      expect(actual_ingress).to match_array(expected_ingress)
    end

    it "continues to network interface creation for an eip nic" do
      client.stub_responses(:create_security_group, group_id: "sg-per-nic")

      expect { nx.create_security_group }.to hop("create_network_interface")
      expect(nic.nic_aws_resource.reload.security_group_id).to eq("sg-per-nic")
      expect(nx.strand.stack.first.fetch("deadline_target")).to eq("attach_eip_network_interface")
    end

    it "tags a dedicated group with its GitHub installation" do
      installation = GithubInstallation.create(
        installation_id: 123,
        name: "test-installation",
        type: "Organization",
        project_id: nic.private_subnet.project_id,
      )
      nic.private_subnet.update(github_installation_id: installation.id)
      nic.nic_aws_resource.update(use_eip: false)
      client.stub_responses(:create_security_group, group_id: "sg-per-nic")
      expect(client).to receive(:create_security_group).with({
        group_name: "aws-us-west-2-#{nic.ubid}-user",
        description: "User security group for aws-us-west-2-#{nic.ubid}",
        vpc_id: "vpc-0123456789abcdefg",
        tag_specifications: Util.aws_tag_specifications("security-group", nic.name, ownership_tags.merge("GithubInstallation" => installation.ubid)),
      }).and_call_original

      expect { nx.create_security_group }.to hop("wait")
    end

    it "recovers the deterministic group after a duplicate create" do
      nic.nic_aws_resource.update(use_eip: false)
      client.stub_responses(:create_security_group, Aws::EC2::Errors::InvalidGroupDuplicate.new(nil, nil))
      client.stub_responses(:describe_security_groups, security_groups: [{group_id: "sg-existing"}])
      expect(client).to receive(:describe_security_groups).with({filters: [
        {name: "vpc-id", values: ["vpc-0123456789abcdefg"]},
        {name: "group-name", values: ["aws-us-west-2-#{nic.ubid}-user"]},
      ]}).and_call_original

      expect { nx.create_security_group }.to hop("wait")
      expect(nic.nic_aws_resource.reload.security_group_id).to eq("sg-existing")
    end

    it "reuses a persisted group that still exists" do
      nic.nic_aws_resource.update(use_eip: false, security_group_id: "sg-existing")
      client.stub_responses(:describe_security_groups, security_groups: [{group_id: "sg-existing"}])
      expect(client).not_to receive(:create_security_group)

      expect { nx.create_security_group }.to hop("wait")
      expect(nic.nic_aws_resource.reload.security_group_id).to eq("sg-existing")
    end

    it "recreates a persisted group that no longer exists" do
      nic.nic_aws_resource.update(use_eip: false, security_group_id: "sg-deleted")
      client.stub_responses(:describe_security_groups, security_groups: [])
      client.stub_responses(:create_security_group, group_id: "sg-recreated")

      expect { nx.create_security_group }.to hop("wait")
      expect(nic.nic_aws_resource.reload.security_group_id).to eq("sg-recreated")
    end

    it "recreates a persisted group when AWS reports it missing" do
      nic.nic_aws_resource.update(use_eip: false, security_group_id: "sg-deleted")
      client.stub_responses(:describe_security_groups, Aws::EC2::Errors::InvalidGroupNotFound.new(nil, nil))
      client.stub_responses(:create_security_group, group_id: "sg-recreated")

      expect { nx.create_security_group }.to hop("wait")
      expect(nic.nic_aws_resource.reload.security_group_id).to eq("sg-recreated")
    end
  end

  describe "#create_network_interface" do
    it "creates a network interface" do
      client.stub_responses(:create_network_interface, network_interface: {network_interface_id: "eni-0123456789abcdefg", ipv_6_addresses: []})
      expect(client).to receive(:create_network_interface).with({subnet_id: "subnet-0123456789abcdefg", private_ip_address: nic.private_ipv4.network.to_s, ipv_6_prefix_count: 1, groups: ["sg-0123456789abcdefg"], tag_specifications: Util.aws_tag_specifications("network-interface", nic.name), client_token: nic.id}).and_call_original
      expect { nx.create_network_interface }.to hop("assign_ipv6_address")
    end

    it "uses the mgmt security group for management nics" do
      nic.update(is_management: true)
      nic.private_subnet.private_subnet_aws_resource.update(mgmt_security_group_id: "sg-mgmt")
      client.stub_responses(:create_network_interface, network_interface: {network_interface_id: "eni-0123456789abcdefg", ipv_6_addresses: []})
      expect(client).to receive(:create_network_interface).with(hash_including(groups: ["sg-mgmt"])).and_call_original
      expect { nx.create_network_interface }.to hop("assign_ipv6_address")
    end

    it "uses the per-NIC security group when one was created" do
      nic.nic_aws_resource.update(security_group_id: "sg-per-nic")
      client.stub_responses(:create_network_interface, network_interface: {network_interface_id: "eni-0123456789abcdefg", ipv_6_addresses: []})
      expect(client).to receive(:create_network_interface).with(hash_including(groups: ["sg-per-nic"])).and_call_original
      expect { nx.create_network_interface }.to hop("assign_ipv6_address")
    end

    it "finds existing network interface when IP is already in use" do
      expect(client).to receive(:create_network_interface).and_raise(Aws::EC2::Errors::InvalidIPAddressInUse.new(nil, "The IP address '10.0.0.1' is already in use."))
      client.stub_responses(:describe_network_interfaces, network_interfaces: [{network_interface_id: "eni-existing123", status: "available"}])
      expect(client).to receive(:describe_network_interfaces).with({
        filters: [
          {name: "subnet-id", values: [nic.nic_aws_resource.subnet_id]},
          {name: "addresses.private-ip-address", values: [nic.private_ipv4.network.to_s]},
          {name: "status", values: ["available"]},
        ],
      }).and_call_original
      expect { nx.create_network_interface }.to hop("assign_ipv6_address")
      expect(nic.nic_aws_resource.reload.network_interface_id).to eq("eni-existing123")
    end

    it "fails when IP is in use but no available network interface found" do
      expect(client).to receive(:create_network_interface).and_raise(Aws::EC2::Errors::InvalidIPAddressInUse.new(nil, "The IP address '10.0.0.1' is already in use."))
      client.stub_responses(:describe_network_interfaces, network_interfaces: [])
      expect { nx.create_network_interface }.to raise_error(RuntimeError, /No available network interface found for IP/)
    end
  end

  describe "#allow_ingress" do
    it "treats an existing ingress permission as converged" do
      params = {
        group_id: "sg-per-nic",
        ip_permissions: [{ip_protocol: "tcp", from_port: 22, to_port: 22, ipv_6_ranges: [{cidr_ipv_6: "2001:db8::/32"}]}],
      }
      client.stub_responses(:authorize_security_group_ingress, Aws::EC2::Errors::InvalidPermissionDuplicate.new(nil, nil))
      expect(client).to receive(:authorize_security_group_ingress).with(params).and_call_original

      nx.allow_ingress("sg-per-nic", "2001:db8::/32")
    end
  end

  describe "#assign_ipv6_address" do
    it "assigns an IPv6 address" do
      nic.nic_aws_resource.update(network_interface_id: "eni-0123456789abcdefg")
      client.stub_responses(:describe_network_interfaces, network_interfaces: [{ipv_6_addresses: []}])
      client.stub_responses(:assign_ipv_6_addresses)
      expect(client).to receive(:assign_ipv_6_addresses).with({network_interface_id: "eni-0123456789abcdefg", ipv_6_address_count: 1}).and_call_original
      expect { nx.assign_ipv6_address }.to hop("wait_network_interface_created")
    end

    it "skips assigning IPv6 addresses if already assigned" do
      nic.nic_aws_resource.update(network_interface_id: "eni-0123456789abcdefg")
      client.stub_responses(:describe_network_interfaces, network_interfaces: [{ipv_6_addresses: [{ipv_6_address: "2a01:4f8:173:1ed3::1"}]}])
      expect(client).not_to receive(:assign_ipv_6_addresses)
      expect { nx.assign_ipv6_address }.to hop("wait_network_interface_created")
    end

    it "naps while waiting for the network interface" do
      nic.nic_aws_resource.update(network_interface_id: "eni-0123456789abcdefg")
      client.stub_responses(:describe_network_interfaces, network_interfaces: [])
      expect { nx.assign_ipv6_address }.to nap(1)
    end
  end

  describe "#wait_network_interface_created" do
    it "checks if network interface is available, if not naps" do
      nic.nic_aws_resource.update(network_interface_id: "eni-0123456789abcdefg")
      client.stub_responses(:describe_network_interfaces, network_interfaces: [{status: "pending"}])
      expect(client).to receive(:describe_network_interfaces).with({filters: [{name: "network-interface-id", values: ["eni-0123456789abcdefg"]}, {name: "tag:Ubicloud", values: ["true"]}]}).and_call_original
      expect { nx.wait_network_interface_created }.to nap(1)
    end

    it "checks if network interface is available, if it is, it allocates an elastic ip and associates it with the network interface" do
      nic.nic_aws_resource.update(network_interface_id: "eni-0123456789abcdefg")
      client.stub_responses(:describe_network_interfaces, network_interfaces: [{status: "available"}])
      client.stub_responses(:allocate_address, allocation_id: "eip-0123456789abcdefg")
      expect(client).to receive(:describe_network_interfaces).with({filters: [{name: "network-interface-id", values: ["eni-0123456789abcdefg"]}, {name: "tag:Ubicloud", values: ["true"]}]}).and_call_original

      expect { nx.wait_network_interface_created }.to hop("allocate_eip")
    end
  end

  describe "#allocate_eip" do
    it "allocates an elastic ip" do
      client.stub_responses(:describe_addresses, addresses: [])
      client.stub_responses(:allocate_address, allocation_id: "eip-0123456789abcdefg")
      expect(client).to receive(:allocate_address).and_call_original
      expect { nx.allocate_eip }.to hop("attach_eip_network_interface")
      expect(nic.nic_aws_resource.reload.eip_allocation_id).to eq("eip-0123456789abcdefg")
    end

    it "reuses an existing elastic ip if available" do
      client.stub_responses(:describe_addresses, addresses: [{allocation_id: "eip-0123456789abcdefg"}])
      expect(client).not_to receive(:allocate_address)
      expect { nx.allocate_eip }.to hop("attach_eip_network_interface")
      expect(nic.nic_aws_resource.reload.eip_allocation_id).to eq("eip-0123456789abcdefg")
    end
  end

  describe "#attach_eip_network_interface" do
    it "associates the elastic ip with the network interface" do
      nic.nic_aws_resource.update(eip_allocation_id: "eip-0123456789abcdefg", network_interface_id: "eni-0123456789abcdefg")
      client.stub_responses(:describe_addresses, addresses: [{allocation_id: "eip-0123456789abcdefg", network_interface_id: nil}])
      client.stub_responses(:associate_address)
      expect(client).to receive(:associate_address).with({allocation_id: "eip-0123456789abcdefg", network_interface_id: nic.nic_aws_resource.network_interface_id}).and_call_original
      expect { nx.attach_eip_network_interface }.to hop("wait")
    end

    it "associates the elastic ip with the network interface if it has no addresses" do
      nic.nic_aws_resource.update(eip_allocation_id: "eip-0123456789abcdefg")
      client.stub_responses(:describe_addresses, addresses: [])
      client.stub_responses(:associate_address)
      expect(client).not_to receive(:associate_address)
      expect { nx.attach_eip_network_interface }.to nap(1)
    end

    it "skips association if elastic ip is already associated" do
      nic.nic_aws_resource.update(eip_allocation_id: "eip-0123456789abcdefg")
      client.stub_responses(:describe_addresses, addresses: [{allocation_id: "eip-0123456789abcdefg", network_interface_id: "eni-existing"}])
      expect(client).not_to receive(:associate_address)
      expect { nx.attach_eip_network_interface }.to hop("wait")
    end
  end

  describe "#wait" do
    it "naps forever" do
      expect { nx.wait }.to nap(1000000000)
    end
  end

  describe "#destroy" do
    it "hops to destroy_entities if the nic_aws_resource is not found" do
      nic.nic_aws_resource.destroy
      nic.reload
      expect { nx.destroy }.to hop("destroy_entities")
    end

    it "waits for AWS to remove a launch-created interface for a use_eip:false nic" do
      nic.nic_aws_resource.update(use_eip: false, network_interface_id: "eni-aws-created")
      expect(client).not_to receive(:delete_network_interface)
      expect { nx.destroy }.to hop("wait_network_interface_deleted")
      expect(Nic[nic.id]).not_to be_nil
      expect(NicAwsResource[nic.id]).not_to be_nil
    end

    it "deletes the network interface" do
      client.stub_responses(:delete_network_interface)
      nic.nic_aws_resource.update(network_interface_id: "eni-0123456789abcdefg")
      expect(client).to receive(:delete_network_interface).with({network_interface_id: "eni-0123456789abcdefg"}).and_call_original
      expect { nx.destroy }.to hop("release_eip")
    end

    it "hops to release_eip if the network interface is not found" do
      client.stub_responses(:delete_network_interface, Aws::EC2::Errors::InvalidNetworkInterfaceIDNotFound.new(nil, "The network interface 'eni-0123456789abcdefg' does not exist."))
      nic.nic_aws_resource.update(network_interface_id: "eni-0123456789abcdefg")
      expect { nx.destroy }.to hop("release_eip")
    end

    it "naps if the network interface is in use" do
      client.stub_responses(:delete_network_interface, Aws::EC2::Errors::InvalidParameterValue.new(nil, "Network interface 'eni-0123456789abcdefg' is currently in use."))
      nic.nic_aws_resource.update(network_interface_id: "eni-0123456789abcdefg")
      expect(client).to receive(:delete_network_interface).with({network_interface_id: "eni-0123456789abcdefg"}).and_call_original
      expect(Clog).to receive(:emit).with("Network interface is in use", instance_of(Hash)).and_call_original
      expect { nx.destroy }.to nap(5)
    end

    it "raises an error if the network interface could not be deleted" do
      client.stub_responses(:delete_network_interface, Aws::EC2::Errors::InvalidParameterValue.new(nil, "Unrelated error"))
      nic.nic_aws_resource.update(network_interface_id: "eni-0123456789abcdefg")
      expect { nx.destroy }.to raise_error(Aws::EC2::Errors::InvalidParameterValue, "Unrelated error")
    end
  end

  describe "#wait_network_interface_deleted" do
    before do
      nic.nic_aws_resource.update(use_eip: false, network_interface_id: "eni-aws-created")
    end

    it "keeps the database rows while the instance still owns the interface" do
      client.stub_responses(:describe_network_interfaces, network_interfaces: [{network_interface_id: "eni-aws-created", status: "in-use"}])
      expect(client).to receive(:describe_network_interfaces).with({network_interface_ids: ["eni-aws-created"]}).and_call_original
      expect(client).not_to receive(:delete_network_interface)

      expect { nx.wait_network_interface_deleted }.to nap(5)
      expect(Nic[nic.id]).not_to be_nil
      expect(NicAwsResource[nic.id]).not_to be_nil
    end

    it "deletes an available interface and waits for confirmed disappearance" do
      client.stub_responses(:describe_network_interfaces, network_interfaces: [{network_interface_id: "eni-aws-created", status: "available"}])
      client.stub_responses(:delete_network_interface)
      expect(client).to receive(:delete_network_interface).with({network_interface_id: "eni-aws-created"}).and_call_original

      expect { nx.wait_network_interface_deleted }.to nap(5)
      expect(Nic[nic.id]).not_to be_nil
      expect(NicAwsResource[nic.id]).not_to be_nil
    end

    it "continues only after AWS no longer returns the interface" do
      client.stub_responses(:describe_network_interfaces, network_interfaces: [])
      expect { nx.wait_network_interface_deleted }.to hop("release_eip")
    end

    it "continues without an AWS lookup when no interface was recorded" do
      nic.nic_aws_resource.update(network_interface_id: nil)
      expect(client).not_to receive(:describe_network_interfaces)

      expect { nx.wait_network_interface_deleted }.to hop("release_eip")
    end

    it "continues when the interface disappears between describe and delete" do
      client.stub_responses(:describe_network_interfaces, network_interfaces: [{network_interface_id: "eni-aws-created", status: "available"}])
      client.stub_responses(:delete_network_interface, Aws::EC2::Errors::InvalidNetworkInterfaceIDNotFound.new(nil, nil))
      expect(client).to receive(:delete_network_interface).with({network_interface_id: "eni-aws-created"}).and_call_original

      expect { nx.wait_network_interface_deleted }.to hop("release_eip")
    end

    it "continues when AWS reports the interface was already deleted" do
      client.stub_responses(:describe_network_interfaces, Aws::EC2::Errors::InvalidNetworkInterfaceIDNotFound.new(nil, nil))
      expect { nx.wait_network_interface_deleted }.to hop("release_eip")
    end
  end

  describe "#release_eip" do
    it "releases the elastic ip" do
      nic.nic_aws_resource.update(eip_allocation_id: "eip-0123456789abcdefg")
      client.stub_responses(:release_address)
      expect(client).to receive(:release_address).with({allocation_id: "eip-0123456789abcdefg"}).and_call_original
      expect { nx.release_eip }.to hop("delete_security_group")
    end

    it "gracefully continues if the nic is not found" do
      nic.nic_aws_resource.update(eip_allocation_id: nil)
      expect { nx.release_eip }.to hop("delete_security_group")
    end

    it "gracefully continues if the nic_aws_resource is not found" do
      nic.nic_aws_resource.destroy
      nic.reload
      expect { nx.release_eip }.to hop("delete_security_group")
    end

    it "hops to delete_security_group if the address is already released" do
      nic.nic_aws_resource.update(eip_allocation_id: "eip-0123456789abcdefg")
      client.stub_responses(:release_address, Aws::EC2::Errors::InvalidAllocationIDNotFound.new(nil, "The address 'eip-0123456789abcdefg' does not exist."))
      expect { nx.release_eip }.to hop("delete_security_group")
    end
  end

  describe "#delete_security_group" do
    it "deletes a per-NIC security group before destroying the database rows" do
      nic.nic_aws_resource.update(security_group_id: "sg-per-nic")
      client.stub_responses(:delete_security_group)
      expect(client).to receive(:delete_security_group).with({group_id: "sg-per-nic"}).and_call_original
      expect { nx.delete_security_group }.to hop("destroy_entities")
      expect(Nic[nic.id]).not_to be_nil
      expect(NicAwsResource[nic.id]).not_to be_nil
    end

    it "retries while an interface still references the group" do
      nic.nic_aws_resource.update(security_group_id: "sg-per-nic")
      client.stub_responses(:delete_security_group, Aws::EC2::Errors::DependencyViolation.new(nil, "resource has a dependent object"))
      expect(Clog).to receive(:emit).with("Security group is in use", instance_of(Hash)).and_call_original

      expect { nx.delete_security_group }.to nap(5)
      expect(Nic[nic.id]).not_to be_nil
      expect(NicAwsResource[nic.id]).not_to be_nil
    end

    it "continues when the group was already deleted" do
      nic.nic_aws_resource.update(security_group_id: "sg-per-nic")
      client.stub_responses(:delete_security_group, Aws::EC2::Errors::InvalidGroupNotFound.new(nil, nil))
      expect { nx.delete_security_group }.to hop("destroy_entities")
    end

    it "skips AWS when the nic has no dedicated group" do
      expect(client).not_to receive(:delete_security_group)
      expect { nx.delete_security_group }.to hop("destroy_entities")
    end

    it "skips AWS when the AWS resource row was already deleted" do
      nic.nic_aws_resource.destroy
      nic.reload
      expect(client).not_to receive(:delete_security_group)

      expect { nx.delete_security_group }.to hop("destroy_entities")
    end
  end

  describe "#destroy_entities" do
    it "destroys the nic and its AWS resource" do
      expect { nx.destroy_entities }.to exit({"msg" => "nic deleted"})
      expect(Nic[nic.id]).to be_nil
      expect(NicAwsResource[nic.id]).to be_nil
    end

    it "gracefully continues if the nic.nic_aws_resource is not found" do
      nic.nic_aws_resource.destroy
      nic.reload
      expect { nx.destroy_entities }.to exit({"msg" => "nic deleted"})
      expect(Nic[nic.id]).to be_nil
    end

    it "gracefully continues if the nic row was already deleted" do
      strand = st
      nic.nic_aws_resource.destroy
      nic.destroy
      expect(Strand[strand.id]).not_to be_nil

      expect { nx.destroy_entities }.to exit({"msg" => "nic deleted"})
    end
  end
end
