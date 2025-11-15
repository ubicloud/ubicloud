# frozen_string_literal: true

RSpec.describe Prog::Vnet::Aws::NicNexus do
  subject(:nx) {
    described_class.new(st)
  }

  let(:st) {
    Strand.create(prog: "Vnet::Aws::NicNexus", stack: [{"subject_id" => nic.id}], label: "start")
  }

  let(:nic) {
    prj = Project.create(name: "test-prj")
    loc = Location.create(name: "us-west-2", provider: "aws", project_id: prj.id, display_name: "aws-us-west-2", ui_name: "AWS US East 1", visible: true)
    LocationCredential.create_with_id(loc.id, access_key: "test-access-key", secret_key: "test-secret-key")
    ps = Prog::Vnet::SubnetNexus.assemble(prj.id, name: "test-ps", location_id: loc.id).subject
    ps.strand.update(label: "wait")
    PrivateSubnetAwsResource.create_with_id(ps.id, security_group_id: "sg-0123456789abcdefg", vpc_id: "vpc-0123456789abcdefg")
    nic = Prog::Vnet::NicNexus.assemble(ps.id, name: "test-nic").subject
    NicAwsResource.create_with_id(nic.id, subnet_id: "subnet-0123456789abcdefg", subnet_az: "us-west-2a")
    nic
  }

  let(:client) {
    Aws::EC2::Client.new(stub_responses: true)
  }

  before do
    allow(nx).to receive(:nic).and_return(nic)
    allow(Aws::EC2::Client).to receive(:new).with(access_key_id: "test-access-key", secret_access_key: "test-secret-key", region: "us-west-2").and_return(client)
  end

  describe "#before_run" do
    it "hops to destroy when needed" do
      expect(nx).to receive(:when_destroy_set?).and_yield
      expect { nx.before_run }.to hop("destroy")
    end

    it "does not hop to destroy if already in the destroy state or one of the other destroying states" do
      expect(nx).to receive(:when_destroy_set?).and_yield.at_least(:once)
      expect(nx.strand).to receive(:label).and_return("destroy")
      expect { nx.before_run }.not_to hop("destroy")
      expect(nx.strand).to receive(:label).and_return("release_eip")
      expect { nx.before_run }.not_to hop("destroy")
      expect(nx.strand).to receive(:label).and_return("delete_subnet")
      expect { nx.before_run }.not_to hop("destroy")
      expect(nx.strand).to receive(:label).and_return("destroy_entities")
      expect { nx.before_run }.not_to hop("destroy")
    end
  end

  describe "#start" do
    it "creates a nic aws resource" do
      NicAwsResource[nic.id].destroy
      expect { nx.start }.to hop("create_subnet")
      expect(NicAwsResource[nic.id]).not_to be_nil
    end
  end

  describe "#create_subnet" do
    it "naps if subnet is not ready" do
      nic.private_subnet.strand.update(label: "create_aws_vpc")
      expect { nx.create_subnet }.to nap(2)
    end

    it "creates a subnet and hops to wait_subnet_created" do
      expect(nic.private_subnet).to receive(:old_aws_subnet?).and_return(false)
      client.stub_responses(:describe_vpcs, vpcs: [{ipv_6_cidr_block_association_set: [{ipv_6_cidr_block: "2600:1f14:1000::/56"}], vpc_id: "vpc-0123456789abcdefg"}])
      client.stub_responses(:describe_subnets, subnets: [])
      client.stub_responses(:create_subnet, subnet: {subnet_id: "subnet-0123456789abcdefg"})
      client.stub_responses(:modify_subnet_attribute)
      expect(client).to receive(:modify_subnet_attribute).with({subnet_id: "subnet-0123456789abcdefg", assign_ipv_6_address_on_creation: {value: true}}).and_call_original
      expect(nic.nic_aws_resource).to receive(:update).with(subnet_id: "subnet-0123456789abcdefg", subnet_az: "a")
      expect(nx).to receive(:az_to_provision_subnet).and_return("a").at_least(:once)
      expect { nx.create_subnet }.to hop("wait_subnet_created")
    end

    it "reuses existing subnet" do
      expect(nic.private_subnet).to receive(:old_aws_subnet?).and_return(false)
      client.stub_responses(:describe_vpcs, vpcs: [{ipv_6_cidr_block_association_set: [{ipv_6_cidr_block: "2600:1f14:1000::/56"}], vpc_id: "vpc-0123456789abcdefg"}])
      client.stub_responses(:describe_subnets, subnets: [{subnet_id: "subnet-existing"}])
      expect(client).not_to receive(:create_route_table)
      expect(nic.nic_aws_resource).to receive(:update).with(subnet_id: "subnet-existing", subnet_az: "a")
      expect(nx).to receive(:az_to_provision_subnet).and_return("a")
      expect { nx.create_subnet }.to hop("wait_subnet_created")
    end

    it "reuses existing subnet for old aws subnet" do
      expect(nic.private_subnet).to receive(:old_aws_subnet?).and_return(true)
      client.stub_responses(:describe_vpcs, vpcs: [{ipv_6_cidr_block_association_set: [{ipv_6_cidr_block: "2600:1f14:1000::/56"}], vpc_id: "vpc-0123456789abcdefg"}])
      client.stub_responses(:describe_subnets, subnets: [{subnet_id: "subnet-existing"}])
      client.stub_responses(:modify_subnet_attribute)
      expect(client).not_to receive(:create_route_table)
      expect(nic.nic_aws_resource).to receive(:update).with(subnet_id: "subnet-existing", subnet_az: "a")
      expect(nx).to receive(:az_to_provision_subnet).and_return("a")
      expect { nx.create_subnet }.to hop("wait_subnet_created")
    end
  end

  describe "#wait_subnet_created" do
    it "just hops to create the network interface for old aws subnet" do
      expect(nic.private_subnet).to receive(:old_aws_subnet?).and_return(true)
      expect { nx.wait_subnet_created }.to hop("create_network_interface")
    end

    it "checks if subnet is available, if not naps" do
      client.stub_responses(:describe_subnets, subnets: [{state: "pending"}])
      expect { nx.wait_subnet_created }.to nap(1)
    end

    it "checks if subnet is available, if so associates with the route_table and hops to create_network_interface" do
      client.stub_responses(:describe_subnets, subnets: [{state: "available"}])
      client.stub_responses(:describe_route_tables, route_tables: [{route_table_id: "rtb-0123456789abcdefg", associations: []}])
      client.stub_responses(:associate_route_table)
      expect(client).to receive(:associate_route_table).with({route_table_id: "rtb-0123456789abcdefg", subnet_id: "subnet-0123456789abcdefg"}).and_call_original
      expect { nx.wait_subnet_created }.to hop("create_network_interface")
    end

    it "checks if subnet is available, doesn't associate with the route_table if it's already associated and hops to create_network_interface" do
      client.stub_responses(:describe_subnets, subnets: [{state: "available"}])
      client.stub_responses(:describe_route_tables, route_tables: [{route_table_id: "rtb-0123456789abcdefg", associations: [{subnet_id: "subnet-0123456789abcdefg"}]}])
      expect(client).not_to receive(:associate_route_table)
      expect { nx.wait_subnet_created }.to hop("create_network_interface")
    end
  end

  describe "#create_network_interface" do
    it "creates a network interface" do
      client.stub_responses(:create_network_interface, network_interface: {network_interface_id: "eni-0123456789abcdefg", ipv_6_addresses: []})
      expect(client).to receive(:create_network_interface).with({subnet_id: "subnet-0123456789abcdefg", private_ip_address: nic.private_ipv4.network.to_s, ipv_6_prefix_count: 1, groups: ["sg-0123456789abcdefg"], tag_specifications: Util.aws_tag_specifications("network-interface", nic.name), client_token: nic.id}).and_call_original
      expect { nx.create_network_interface }.to hop("assign_ipv6_address")
    end
  end

  describe "#assign_ipv6_address" do
    it "assigns an IPv6 address" do
      client.stub_responses(:describe_network_interfaces, network_interfaces: [{ipv_6_addresses: []}])
      expect(nic.nic_aws_resource).to receive(:network_interface_id).and_return("eni-0123456789abcdefg").at_least(:once)
      client.stub_responses(:assign_ipv_6_addresses)
      expect(client).to receive(:assign_ipv_6_addresses).with({network_interface_id: "eni-0123456789abcdefg", ipv_6_address_count: 1}).and_call_original
      expect { nx.assign_ipv6_address }.to hop("wait_network_interface_created")
    end

    it "skips assigning IPv6 addresses if already assigned" do
      client.stub_responses(:describe_network_interfaces, network_interfaces: [{ipv_6_addresses: [{ipv_6_address: "2a01:4f8:173:1ed3::1"}]}])
      expect(client).not_to receive(:assign_ipv_6_addresses)
      expect { nx.assign_ipv6_address }.to hop("wait_network_interface_created")
    end
  end

  describe "#wait_network_interface_created" do
    it "checks if network interface is available, if not naps" do
      client.stub_responses(:describe_network_interfaces, network_interfaces: [{status: "pending"}])
      expect(nic.nic_aws_resource).to receive(:network_interface_id).and_return("eni-0123456789abcdefg").at_least(:once)
      expect(client).to receive(:describe_network_interfaces).with({filters: [{name: "network-interface-id", values: ["eni-0123456789abcdefg"]}, {name: "tag:Ubicloud", values: ["true"]}]}).and_call_original
      expect { nx.wait_network_interface_created }.to nap(1)
    end

    it "checks if network interface is available, if it is, it allocates an elastic ip and associates it with the network interface" do
      client.stub_responses(:describe_network_interfaces, network_interfaces: [{status: "available"}])
      client.stub_responses(:allocate_address, allocation_id: "eip-0123456789abcdefg")
      expect(nic.nic_aws_resource).to receive(:network_interface_id).and_return("eni-0123456789abcdefg").at_least(:once)
      expect(client).to receive(:describe_network_interfaces).with({filters: [{name: "network-interface-id", values: ["eni-0123456789abcdefg"]}, {name: "tag:Ubicloud", values: ["true"]}]}).and_call_original

      expect { nx.wait_network_interface_created }.to hop("allocate_eip")
    end
  end

  describe "#allocate_eip" do
    it "allocates an elastic ip" do
      client.stub_responses(:describe_addresses, addresses: [])
      client.stub_responses(:allocate_address, allocation_id: "eip-0123456789abcdefg")
      expect(client).to receive(:allocate_address).and_call_original
      expect(nic.nic_aws_resource).to receive(:update).with(eip_allocation_id: "eip-0123456789abcdefg")
      expect { nx.allocate_eip }.to hop("attach_eip_network_interface")
    end

    it "reuses an existing elastic ip if available" do
      client.stub_responses(:describe_addresses, addresses: [{allocation_id: "eip-0123456789abcdefg"}])
      expect(client).not_to receive(:allocate_address)
      expect(nic.nic_aws_resource).to receive(:update).with(eip_allocation_id: "eip-0123456789abcdefg")
      expect { nx.allocate_eip }.to hop("attach_eip_network_interface")
    end
  end

  describe "#attach_eip_network_interface" do
    it "associates the elastic ip with the network interface" do
      expect(nic.nic_aws_resource).to receive(:eip_allocation_id).and_return("eip-0123456789abcdefg").at_least(:once)
      client.stub_responses(:describe_addresses, addresses: [{allocation_id: "eip-0123456789abcdefg", network_interface_id: nil}])
      client.stub_responses(:associate_address)
      expect(client).to receive(:associate_address).with({allocation_id: "eip-0123456789abcdefg", network_interface_id: nic.nic_aws_resource.network_interface_id}).and_call_original
      expect { nx.attach_eip_network_interface }.to hop("wait")
    end

    it "skips association if elastic ip is already associated" do
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
    it "deletes the network interface" do
      client.stub_responses(:describe_network_interfaces, network_interfaces: [{status: "available"}])
      client.stub_responses(:delete_network_interface)
      expect(nic.nic_aws_resource).to receive(:network_interface_id).and_return("eni-0123456789abcdefg").at_least(:once)
      expect(client).to receive(:delete_network_interface).with({network_interface_id: "eni-0123456789abcdefg"}).and_call_original
      expect { nx.destroy }.to hop("release_eip")
    end

    it "doesn't nap if network_interfaces are empty" do
      client.stub_responses(:describe_network_interfaces, network_interfaces: [])
      client.stub_responses(:delete_network_interface, Aws::EC2::Errors::InvalidNetworkInterfaceIDNotFound.new(nil, "The network interface 'eni-0123456789abcdefg' does not exist."))
      expect(nic.nic_aws_resource).to receive(:network_interface_id).and_return("eni-0123456789abcdefg").at_least(:once)
      expect { nx.destroy }.to hop("release_eip")
    end

    it "hops to release_eip if the network interface is not found" do
      client.stub_responses(:delete_network_interface, Aws::EC2::Errors::InvalidNetworkInterfaceIDNotFound.new(nil, "The network interface 'eni-0123456789abcdefg' does not exist."))
      expect(nic.nic_aws_resource).to receive(:network_interface_id).and_return("eni-0123456789abcdefg").at_least(:once)
      expect { nx.destroy }.to hop("release_eip")
    end
  end

  describe "#release_eip" do
    it "releases the elastic ip" do
      expect(nic.nic_aws_resource).to receive(:eip_allocation_id).and_return("eip-0123456789abcdefg").at_least(:once)
      client.stub_responses(:release_address)
      expect(client).to receive(:release_address).with({allocation_id: "eip-0123456789abcdefg"}).and_call_original
      expect { nx.release_eip }.to hop("delete_subnet")
    end

    it "gracefully continues if the nic is not found" do
      expect(nic.nic_aws_resource).to receive(:eip_allocation_id).and_return(nil).at_least(:once)
      expect { nx.release_eip }.to hop("delete_subnet")
    end

    it "gracefully continues if the nic_aws_resource is not found" do
      expect(nic).to receive(:nic_aws_resource).and_return(nil).at_least(:once)
      expect { nx.release_eip }.to hop("delete_subnet")
    end

    it "hops to delete_subnet if the eip_allocation_id is found" do
      expect(nic.nic_aws_resource).to receive(:eip_allocation_id).and_return("eip-0123456789abcdefg").at_least(:once)
      expect { nx.release_eip }.to hop("delete_subnet")
    end

    it "hops to delete_subnet if the address is already released" do
      client.stub_responses(:describe_addresses, addresses: [{allocation_id: "eip-0123456789abcdefg"}])
      client.stub_responses(:release_address, Aws::EC2::Errors::InvalidAllocationIDNotFound.new(nil, "The address 'eip-0123456789abcdefg' does not exist."))
      expect { nx.release_eip }.to hop("delete_subnet")
    end
  end

  describe "#delete_subnet" do
    it "deletes the subnet" do
      client.stub_responses(:delete_subnet)
      expect(client).to receive(:delete_subnet).with({subnet_id: nic.nic_aws_resource.subnet_id}).and_call_original
      expect { nx.delete_subnet }.to hop("destroy_entities")
    end

    it "gracefully continues if the nic is not found" do
      client.stub_responses(:delete_subnet, Aws::EC2::Errors::InvalidSubnetIDNotFound.new(nil, "The subnet 'subnet-0123456789abcdefg' does not exist."))
      expect(nic.nic_aws_resource).to receive(:subnet_id).and_return(nil).at_least(:once)
      expect { nx.delete_subnet }.to hop("destroy_entities")
    end

    it "raises an error if the subnet could not be deleted but we are the only nic" do
      client.stub_responses(:delete_subnet, Aws::EC2::Errors::DependencyViolation.new(nil, "The subnet 'subnet-0123456789abcdefg' could not be deleted because it is associated with the network interface 'eni-0123456789abcdefg'."))
      expect(nic.private_subnet).to receive(:nics).and_return([nic]).at_least(:once)
      expect { nx.delete_subnet }.to raise_error(Aws::EC2::Errors::DependencyViolation)
    end

    it "gracefully continues if the subnet could not be deleted but we are not the only nic" do
      client.stub_responses(:delete_subnet, Aws::EC2::Errors::DependencyViolation.new(nil, "The subnet 'subnet-0123456789abcdefg' could not be deleted because it is associated with the network interface 'eni-0123456789abcdefg'."))
      expect(nic.private_subnet).to receive(:nics).and_return([nic, instance_double(Nic)]).at_least(:once)
      expect { nx.delete_subnet }.to hop("destroy_entities")
    end
  end

  describe "#destroy_entities" do
    it "refreshes the keys and destroys the nic" do
      expect(nic.nic_aws_resource).to receive(:destroy)
      expect(nic).to receive(:destroy)
      expect { nx.destroy_entities }.to exit({"msg" => "nic deleted"})
    end

    it "gracefully continues if the nic.nic_aws_resource is not found" do
      expect(nic).to receive(:nic_aws_resource).and_return(nil).at_least(:once)
      expect(nic).to receive(:destroy).and_return(true).once
      expect { nx.destroy_entities }.to exit({"msg" => "nic deleted"})
    end

    it "gracefully continues if the nic is not found" do
      expect(nx).to receive(:nic).and_return(nil).at_least(:once)
      expect { nx.destroy_entities }.to exit({"msg" => "nic deleted"})
    end
  end

  describe "#az_to_provision_subnet" do
    it "returns the az if set" do
      expect(nx).to receive(:frame).and_return({"availability_zone" => "a"})
      expect(nx.az_to_provision_subnet).to eq("a")
    end

    it "returns an az that is not in excluded_availability_zones" do
      expect(nx).to receive(:frame).and_return({"exclude_availability_zones" => ["a"]}).at_least(:once)
      expect(["b", "c"]).to include(nx.az_to_provision_subnet) # rubocop:disable RSpec/ExpectActual
    end

    it "returns a if nothing is available" do
      expect(nx).to receive(:frame).and_return({"exclude_availability_zones" => ["a", "b", "c"]}).at_least(:once)
      expect(nx.az_to_provision_subnet).to eq("a")
    end
  end
end
