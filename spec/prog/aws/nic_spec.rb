# frozen_string_literal: true

RSpec.describe Prog::Aws::Nic do
  subject(:nx) {
    described_class.new(st)
  }

  let(:st) {
    Strand.create_with_id(prog: "Aws::Nic", stack: [{"subject_id" => nic.id}], label: "create_network_interface")
  }

  let(:nic) {
    prj = Project.create_with_id(name: "test-prj")
    loc = Location.create_with_id(name: "us-east-1", provider: "aws", project_id: prj.id, display_name: "aws-us-east-1", ui_name: "AWS US East 1", visible: true)
    LocationCredential.create_with_id(access_key: "test-access-key", secret_key: "test-secret-key") { _1.id = loc.id }
    ps = Prog::Vnet::SubnetNexus.assemble(prj.id, name: "test-ps", location_id: loc.id).subject
    PrivateSubnetAwsResource.create(subnet_id: "subnet-0123456789abcdefg", security_group_id: "sg-0123456789abcdefg") { _1.id = ps.id }
    Prog::Vnet::NicNexus.assemble(ps.id, name: "test-nic").subject
  }

  let(:client) {
    instance_double(Aws::EC2::Client)
  }

  before do
    allow(nx).to receive(:nic).and_return(nic)
    expect(Aws::EC2::Client).to receive(:new).with(access_key_id: "test-access-key", secret_access_key: "test-secret-key", region: "us-east-1").and_return(client)
  end

  describe "#create_network_interface" do
    it "creates a network interface" do
      expect(client).to receive(:create_network_interface).with({subnet_id: "subnet-0123456789abcdefg", private_ip_address: nic.private_ipv4.network.to_s, ipv_6_prefix_count: 1, groups: ["sg-0123456789abcdefg"]}).and_return(instance_double(Aws::EC2::Types::CreateNetworkInterfaceResult, network_interface: instance_double(Aws::EC2::Types::NetworkInterface, network_interface_id: "eni-0123456789abcdefg")))
      expect(client).to receive(:assign_ipv_6_addresses).with({network_interface_id: "eni-0123456789abcdefg", ipv_6_address_count: 1})
      expect(nic).to receive(:update).with(name: "eni-0123456789abcdefg")
      expect { nx.create_network_interface }.to hop("wait_network_interface_created")
    end
  end

  describe "#wait_network_interface_created" do
    it "checks if network interface is available, if not naps" do
      expect(client).to receive(:describe_network_interfaces).with({filters: [{name: "network-interface-id", values: [nic.name]}]}).and_return(instance_double(Aws::EC2::Types::DescribeNetworkInterfacesResult, network_interfaces: [instance_double(Aws::EC2::Types::NetworkInterface, status: "pending")]))
      expect { nx.wait_network_interface_created }.to nap(1)
    end

    it "checks if network interface is available, if it is, it allocates an elastic ip and associates it with the network interface" do
      expect(client).to receive(:describe_network_interfaces).with({filters: [{name: "network-interface-id", values: [nic.name]}]}).and_return(instance_double(Aws::EC2::Types::DescribeNetworkInterfacesResult, network_interfaces: [instance_double(Aws::EC2::Types::NetworkInterface, status: "available")]))
      expect(client).to receive(:allocate_address).with({domain: "vpc"}).and_return(instance_double(Aws::EC2::Types::AllocateAddressResult, allocation_id: "eip-0123456789abcdefg"))
      expect(client).to receive(:associate_address).with({allocation_id: "eip-0123456789abcdefg", network_interface_id: nic.name})
      expect { nx.wait_network_interface_created }.to exit({"msg" => "nic created"})
    end
  end

  describe "#destroy" do
    it "deletes the network interface" do
      expect(client).to receive(:delete_network_interface).with({network_interface_id: nic.name})
      expect { nx.destroy }.to hop("release_eip")
    end

    it "hops to release_eip if the network interface is not found" do
      expect(client).to receive(:delete_network_interface).with({network_interface_id: nic.name}).and_raise(Aws::EC2::Errors::InvalidNetworkInterfaceIDNotFound.new(nil, "The network interface 'eni-0123456789abcdefg' does not exist."))
      expect { nx.destroy }.to hop("release_eip")
    end
  end

  describe "#release_eip" do
    it "releases the elastic ip" do
      expect(client).to receive(:describe_addresses).with({filters: [{name: "network-interface-id", values: [nic.name]}]}).and_return(instance_double(Aws::EC2::Types::DescribeAddressesResult, addresses: [instance_double(Aws::EC2::Types::Address, allocation_id: "eip-0123456789abcdefg")]))
      expect(client).to receive(:release_address).with({allocation_id: "eip-0123456789abcdefg"})
      expect { nx.release_eip }.to exit({"msg" => "nic destroyed"})
    end

    it "pops if the network interface is not found" do
      expect(client).to receive(:describe_addresses).with({filters: [{name: "network-interface-id", values: [nic.name]}]}).and_return(instance_double(Aws::EC2::Types::DescribeAddressesResult, addresses: []))
      expect { nx.release_eip }.to exit({"msg" => "nic destroyed"})
    end

    it "pops if the address is already released" do
      expect(client).to receive(:describe_addresses).with({filters: [{name: "network-interface-id", values: [nic.name]}]}).and_return(instance_double(Aws::EC2::Types::DescribeAddressesResult, addresses: [instance_double(Aws::EC2::Types::Address, allocation_id: "eip-0123456789abcdefg")]))
      expect(client).to receive(:release_address).with({allocation_id: "eip-0123456789abcdefg"}).and_raise(Aws::EC2::Errors::InvalidNetworkInterfaceIDNotFound.new(nil, "The network interface 'eni-0123456789abcdefg' does not exist."))
      expect { nx.release_eip }.to exit({"msg" => "nic destroyed"})
    end
  end
end
