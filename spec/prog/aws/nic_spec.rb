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
    LocationCredential.create_with_id(access_key: "test-access-key", secret_key: "test-secret-key") { it.id = loc.id }
    ps = Prog::Vnet::SubnetNexus.assemble(prj.id, name: "test-ps", location_id: loc.id).subject
    PrivateSubnetAwsResource.create(subnet_id: "subnet-0123456789abcdefg", security_group_id: "sg-0123456789abcdefg") { it.id = ps.id }
    nic = Prog::Vnet::NicNexus.assemble(ps.id, name: "test-nic").subject
    NicAwsResource.create { it.id = nic.id }
    nic
  }

  let(:client) {
    Aws::EC2::Client.new(stub_responses: true)
  }

  before do
    allow(nx).to receive(:nic).and_return(nic)
    allow(Aws::EC2::Client).to receive(:new).with(access_key_id: "test-access-key", secret_access_key: "test-secret-key", region: "us-east-1").and_return(client)
  end

  describe "#create_network_interface" do
    it "creates a network interface" do
      client.stub_responses(:create_network_interface, network_interface: {network_interface_id: "eni-0123456789abcdefg"})
      client.stub_responses(:assign_ipv_6_addresses)
      expect(client).to receive(:create_network_interface).with({subnet_id: "subnet-0123456789abcdefg", private_ip_address: nic.private_ipv4.network.to_s, ipv_6_prefix_count: 1, groups: ["sg-0123456789abcdefg"], tag_specifications: [{resource_type: "network-interface", tags: [{key: "Ubicloud", value: "true"}]}]}).and_call_original
      expect(client).to receive(:assign_ipv_6_addresses).with({network_interface_id: "eni-0123456789abcdefg", ipv_6_address_count: 1}).and_call_original
      expect(nic).to receive(:update).with(name: "eni-0123456789abcdefg")
      expect { nx.create_network_interface }.to hop("wait_network_interface_created")
    end
  end

  describe "#wait_network_interface_created" do
    it "checks if network interface is available, if not naps" do
      client.stub_responses(:describe_network_interfaces, network_interfaces: [{status: "pending"}])
      expect(client).to receive(:describe_network_interfaces).with({filters: [{name: "network-interface-id", values: [nic.name]}, {name: "tag:Ubicloud", values: ["true"]}]}).and_call_original
      expect { nx.wait_network_interface_created }.to nap(1)
    end

    it "checks if network interface is available, if it is, it allocates an elastic ip and associates it with the network interface" do
      client.stub_responses(:describe_network_interfaces, network_interfaces: [{status: "available"}])
      client.stub_responses(:allocate_address, allocation_id: "eip-0123456789abcdefg")
      expect(client).to receive(:describe_network_interfaces).with({filters: [{name: "network-interface-id", values: [nic.name]}, {name: "tag:Ubicloud", values: ["true"]}]}).and_call_original
      expect(nic.nic_aws_resource).to receive(:update).with(eip_allocation_id: "eip-0123456789abcdefg").and_call_original

      expect { nx.wait_network_interface_created }.to hop("attach_eip_network_interface")
    end
  end

  describe "#attach_eip_network_interface" do
    it "associates the elastic ip with the network interface" do
      expect(nic.nic_aws_resource).to receive(:eip_allocation_id).and_return("eip-0123456789abcdefg")
      client.stub_responses(:associate_address)
      expect(client).to receive(:associate_address).with({allocation_id: "eip-0123456789abcdefg", network_interface_id: nic.name}).and_call_original
      expect { nx.attach_eip_network_interface }.to exit({"msg" => "nic created"})
    end
  end

  describe "#destroy" do
    it "deletes the network interface" do
      client.stub_responses(:delete_network_interface)
      expect(client).to receive(:delete_network_interface).with({network_interface_id: nic.name}).and_call_original
      expect { nx.destroy }.to hop("release_eip")
    end

    it "hops to release_eip if the network interface is not found" do
      client.stub_responses(:delete_network_interface, Aws::EC2::Errors::InvalidNetworkInterfaceIDNotFound.new(nil, "The network interface 'eni-0123456789abcdefg' does not exist."))
      expect { nx.destroy }.to hop("release_eip")
    end
  end

  describe "#release_eip" do
    it "releases the elastic ip" do
      expect(nic.nic_aws_resource).to receive(:eip_allocation_id).and_return("eip-0123456789abcdefg")
      client.stub_responses(:release_address)
      expect(client).to receive(:release_address).with({allocation_id: "eip-0123456789abcdefg"}).and_call_original
      expect { nx.release_eip }.to exit({"msg" => "nic destroyed"})
    end

    it "pops if the address is already released" do
      client.stub_responses(:describe_addresses, addresses: [{allocation_id: "eip-0123456789abcdefg"}])
      client.stub_responses(:release_address, Aws::EC2::Errors::InvalidAllocationIDNotFound.new(nil, "The address 'eip-0123456789abcdefg' does not exist."))
      expect { nx.release_eip }.to exit({"msg" => "nic destroyed"})
    end
  end
end
