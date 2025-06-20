# frozen_string_literal: true

RSpec.describe Prog::Aws::Vpc do
  subject(:nx) {
    described_class.new(st)
  }

  let(:st) {
    Strand.create_with_id(prog: "Aws::Vpc", stack: [{"subject_id" => ps.id}], label: "create_vpc")
  }

  let(:ps) {
    prj = Project.create_with_id(name: "test-prj")
    loc = Location.create_with_id(name: "us-west-2", provider: "aws", project_id: prj.id, display_name: "aws-us-west-2", ui_name: "AWS US East 1", visible: true)
    LocationCredential.create_with_id(access_key: "test-access-key", secret_key: "test-secret-key") { it.id = loc.id }
    ps = Prog::Vnet::SubnetNexus.assemble(prj.id, name: "test-ps", location_id: loc.id).subject
    PrivateSubnetAwsResource.create { it.id = ps.id }
    ps
  }

  let(:client) {
    Aws::EC2::Client.new(stub_responses: true)
  }

  before do
    allow(nx).to receive(:private_subnet).and_return(ps)
    expect(Aws::EC2::Client).to receive(:new).with(access_key_id: "test-access-key", secret_access_key: "test-secret-key", region: "us-west-2").and_return(client)
  end

  describe "#create_vpc" do
    it "creates a vpc" do
      expect(client).to receive(:create_vpc).with({cidr_block: ps.net4.to_s, amazon_provided_ipv_6_cidr_block: true, tag_specifications: [{resource_type: "vpc", tags: [{key: "Ubicloud", value: "true"}]}]}).and_return(instance_double(Aws::EC2::Types::CreateVpcResult, vpc: instance_double(Aws::EC2::Types::Vpc, vpc_id: "vpc-0123456789abcdefg")))
      expect(ps).to receive(:update).with(name: "vpc-0123456789abcdefg")
      expect(ps.private_subnet_aws_resource).to receive(:update).with(vpc_id: "vpc-0123456789abcdefg")
      expect { nx.create_vpc }.to hop("wait_vpc_created")
    end
  end

  describe "#wait_vpc_created" do
    before do
      client.stub_responses(:create_security_group, group_id: "sg-0123456789abcdefg")
      client.stub_responses(:authorize_security_group_ingress)
    end

    it "checks if vpc is available, if not naps" do
      client.stub_responses(:describe_vpcs, vpcs: [{state: "pending"}])
      expect { nx.wait_vpc_created }.to nap(1)
    end

    it "creates a security group and authorizes ingress" do
      client.stub_responses(:describe_vpcs, vpcs: [{state: "available"}])

      expect(client).to receive(:describe_vpcs).with({filters: [{name: "vpc-id", values: [ps.name]}]}).and_call_original
      expect(client).to receive(:create_security_group).with({group_name: "aws-us-west-2-#{ps.ubid}", description: "Security group for aws-us-west-2-#{ps.ubid}", vpc_id: ps.name, tag_specifications: [{resource_type: "security-group", tags: [{key: "Ubicloud", value: "true"}]}]}).and_call_original
      ps.firewalls.map { it.firewall_rules.map { |fw| fw.destroy } }
      FirewallRule.create_with_id(firewall_id: ps.firewalls.first.id, cidr: "0.0.0.1/32", port_range: 22..80)
      ps.reload
      expect(client).to receive(:authorize_security_group_ingress).with({group_id: "sg-0123456789abcdefg", ip_permissions: [{ip_protocol: "tcp", from_port: 22, to_port: 80, ip_ranges: [{cidr_ip: "0.0.0.1/32"}]}]}).and_call_original
      expect { nx.wait_vpc_created }.to hop("create_subnet")
    end

    it "does not create a security group if it already exists" do
      client.stub_responses(:describe_vpcs, vpcs: [{state: "available"}])
      client.stub_responses(:create_security_group, Aws::EC2::Errors::InvalidGroupDuplicate.new(nil, nil))
      client.stub_responses(:describe_security_groups, security_groups: [{group_id: "sg-0123456789abcdefg"}])

      ps.firewalls.map { it.firewall_rules.map { |fw| fw.destroy } }
      FirewallRule.create_with_id(firewall_id: ps.firewalls.first.id, cidr: "0.0.0.1/32", port_range: 22..80)
      FirewallRule.create_with_id(firewall_id: ps.firewalls.first.id, cidr: "::/32", port_range: 22..80)
      ps.reload
      expect { nx.wait_vpc_created }.to hop("create_subnet")
    end
  end

  describe "#create_subnet" do
    it "creates a subnet and hops to wait_subnet_created" do
      client.stub_responses(:describe_vpcs, vpcs: [{ipv_6_cidr_block_association_set: [{ipv_6_cidr_block: "2600:1f14:1000::/56"}], vpc_id: ps.name}])
      client.stub_responses(:create_subnet, subnet: {subnet_id: "subnet-0123456789abcdefg"})
      client.stub_responses(:modify_subnet_attribute)
      expect(client).to receive(:modify_subnet_attribute).with({subnet_id: "subnet-0123456789abcdefg", assign_ipv_6_address_on_creation: {value: true}}).and_call_original
      expect(ps.private_subnet_aws_resource).to receive(:update).with(subnet_id: "subnet-0123456789abcdefg")
      expect { nx.create_subnet }.to hop("wait_subnet_created")
    end
  end

  describe "#wait_subnet_created" do
    it "checks if subnet is available, if not naps" do
      client.stub_responses(:describe_subnets, subnets: [{state: "pending"}])
      expect { nx.wait_subnet_created }.to nap(1)
    end

    it "checks if subnet is available, if so hops to create_route_table" do
      client.stub_responses(:describe_subnets, subnets: [{state: "available"}])
      expect { nx.wait_subnet_created }.to hop("create_route_table")
    end
  end

  describe "#create_route_table" do
    it "creates a route table and hops to wait_route_table_created" do
      client.stub_responses(:describe_route_tables, route_tables: [{route_table_id: "rtb-0123456789abcdefg"}])
      client.stub_responses(:create_internet_gateway, internet_gateway: {internet_gateway_id: "igw-0123456789abcdefg"})
      client.stub_responses(:create_route)
      client.stub_responses(:attach_internet_gateway)
      client.stub_responses(:associate_route_table)
      expect(ps.private_subnet_aws_resource).to receive(:update).with(internet_gateway_id: "igw-0123456789abcdefg")
      expect(ps.private_subnet_aws_resource).to receive(:update).with(route_table_id: "rtb-0123456789abcdefg")
      expect(client).to receive(:attach_internet_gateway).with({internet_gateway_id: "igw-0123456789abcdefg", vpc_id: ps.name}).and_call_original
      expect(client).to receive(:create_route).with({route_table_id: "rtb-0123456789abcdefg", destination_ipv_6_cidr_block: "::/0", gateway_id: "igw-0123456789abcdefg"}).and_call_original
      expect(client).to receive(:create_route).with({route_table_id: "rtb-0123456789abcdefg", destination_cidr_block: "0.0.0.0/0", gateway_id: "igw-0123456789abcdefg"}).and_call_original
      expect(client).to receive(:associate_route_table).with({route_table_id: "rtb-0123456789abcdefg", subnet_id: ps.private_subnet_aws_resource.subnet_id}).and_call_original
      expect { nx.create_route_table }.to exit({"msg" => "subnet created"})
    end

    it "omits if the route already exists" do
      client.stub_responses(:describe_route_tables, route_tables: [{route_table_id: "rtb-0123456789abcdefg"}])
      client.stub_responses(:create_internet_gateway, internet_gateway: {internet_gateway_id: "igw-0123456789abcdefg"})
      client.stub_responses(:create_route, Aws::EC2::Errors::RouteAlreadyExists.new(nil, nil))
      client.stub_responses(:attach_internet_gateway)
      client.stub_responses(:associate_route_table)
      expect(client).to receive(:describe_route_tables).with({filters: [{name: "vpc-id", values: [ps.name]}]}).and_call_original
      expect(ps.private_subnet_aws_resource).to receive(:update).with(internet_gateway_id: "igw-0123456789abcdefg")
      expect(ps.private_subnet_aws_resource).to receive(:update).with(route_table_id: "rtb-0123456789abcdefg")
      expect(client).to receive(:attach_internet_gateway).with({internet_gateway_id: "igw-0123456789abcdefg", vpc_id: ps.name}).and_call_original
      expect(client).to receive(:create_route).with({route_table_id: "rtb-0123456789abcdefg", destination_ipv_6_cidr_block: "::/0", gateway_id: "igw-0123456789abcdefg"}).and_call_original
      expect(client).to receive(:associate_route_table).with({route_table_id: "rtb-0123456789abcdefg", subnet_id: ps.private_subnet_aws_resource.subnet_id})
      expect { nx.create_route_table }.to exit({"msg" => "subnet created"})
    end
  end

  describe "#destroy" do
    before do
      ps.private_subnet_aws_resource.update(subnet_id: "subnet-0123456789abcdefg", security_group_id: "sg-0123456789abcdefg", internet_gateway_id: "igw-0123456789abcdefg")
    end

    it "deletes the subnet and hops to delete_security_group" do
      client.stub_responses(:delete_subnet)
      expect(client).to receive(:delete_subnet).with({subnet_id: "subnet-0123456789abcdefg"}).and_call_original
      expect { nx.destroy }.to hop("delete_security_group")
    end

    it "hops to delete_security_group if subnet is not found" do
      client.stub_responses(:delete_subnet, Aws::EC2::Errors::InvalidSubnetIDNotFound.new(nil, nil))
      expect { nx.destroy }.to hop("delete_security_group")
    end

    it "deletes the security group and hops to delete_internet_gateway" do
      client.stub_responses(:delete_security_group)
      expect(client).to receive(:delete_security_group).with({group_id: "sg-0123456789abcdefg"}).and_call_original
      expect { nx.delete_security_group }.to hop("delete_internet_gateway")
    end

    it "hops to delete_internet_gateway if security group is not found" do
      client.stub_responses(:delete_security_group, Aws::EC2::Errors::InvalidGroupNotFound.new(nil, nil))
      expect { nx.delete_security_group }.to hop("delete_internet_gateway")
    end

    it "deletes the internet gateway and hops to delete_vpc" do
      client.stub_responses(:delete_internet_gateway)
      client.stub_responses(:detach_internet_gateway)
      expect(client).to receive(:delete_internet_gateway).with({internet_gateway_id: "igw-0123456789abcdefg"}).and_call_original
      expect(client).to receive(:detach_internet_gateway).with({internet_gateway_id: "igw-0123456789abcdefg", vpc_id: ps.name}).and_call_original
      expect { nx.delete_internet_gateway }.to hop("delete_vpc")
    end

    it "hops to delete_vpc if internet gateway is not found" do
      client.stub_responses(:delete_internet_gateway, Aws::EC2::Errors::InvalidInternetGatewayIDNotFound.new(nil, nil))
      client.stub_responses(:detach_internet_gateway)
      expect { nx.delete_internet_gateway }.to hop("delete_vpc")
    end

    it "deletes the vpc" do
      client.stub_responses(:delete_vpc)
      expect(client).to receive(:delete_vpc).with({vpc_id: ps.name}).and_call_original
      expect { nx.delete_vpc }.to exit({"msg" => "vpc destroyed"})
    end

    it "pops if vpc is not found" do
      client.stub_responses(:delete_vpc, Aws::EC2::Errors::InvalidVpcIDNotFound.new(nil, nil))
      expect { nx.delete_vpc }.to exit({"msg" => "vpc destroyed"})
    end
  end
end
