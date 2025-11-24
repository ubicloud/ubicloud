# frozen_string_literal: true

RSpec.describe Prog::Vnet::Aws::VpcNexus do
  subject(:nx) {
    described_class.new(st)
  }

  let(:st) {
    Strand.create(prog: "Aws::Vnet::VpcNexus", stack: [{"subject_id" => ps.id}], label: "start")
  }

  let(:ps) {
    prj = Project.create(name: "test-prj")
    loc = Location.create(name: "us-west-2", provider: "aws", project_id: prj.id, display_name: "aws-us-west-2", ui_name: "AWS US East 1", visible: true)
    LocationCredential.create_with_id(loc.id, access_key: "test-access-key", secret_key: "test-secret-key")
    ps = Prog::Vnet::SubnetNexus.assemble(prj.id, name: "test-ps", location_id: loc.id).subject
    PrivateSubnetAwsResource.create_with_id(ps.id)
    ps
  }

  let(:client) {
    Aws::EC2::Client.new(stub_responses: true)
  }

  before do
    allow(nx).to receive(:private_subnet).and_return(ps)
    allow(Aws::EC2::Client).to receive(:new).with(access_key_id: "test-access-key", secret_access_key: "test-secret-key", region: "us-west-2").and_return(client)
  end

  it "hops to destroy if when_destroy_set?" do
    expect(nx).to receive(:when_destroy_set?).and_yield
    expect { nx.before_run }.to hop("destroy")
  end

  it "does not hop to destroy if already destroying" do
    expect(nx).to receive(:when_destroy_set?).and_yield
    expect(nx).to receive(:when_destroying_set?).and_yield
    expect { nx.before_run }.not_to hop("destroy")
  end

  describe "#start" do
    it "creates PrivateSubnetAwsResource and hops to create_vpc" do
      expect(PrivateSubnetAwsResource).to receive(:create_with_id).with(ps.id)
      expect { nx.start }.to hop("create_vpc")
    end
  end

  describe "#create_vpc" do
    it "creates a vpc" do
      client.stub_responses(:describe_vpcs, vpcs: [])
      expect(client).to receive(:create_vpc).with({cidr_block: ps.net4.to_s, amazon_provided_ipv_6_cidr_block: true, tag_specifications: Util.aws_tag_specifications("vpc", ps.name)}).and_return(instance_double(Aws::EC2::Types::CreateVpcResult, vpc: instance_double(Aws::EC2::Types::Vpc, vpc_id: "vpc-0123456789abcdefg")))
      expect(ps.private_subnet_aws_resource).to receive(:update).with(vpc_id: "vpc-0123456789abcdefg")
      expect { nx.create_vpc }.to hop("wait_vpc_created")
    end

    it "reuses existing vpc" do
      client.stub_responses(:describe_vpcs, vpcs: [{vpc_id: "vpc-existing"}])
      expect(client).not_to receive(:create_vpc)
      expect(ps.private_subnet_aws_resource).to receive(:update).with(vpc_id: "vpc-existing")
      expect { nx.create_vpc }.to hop("wait_vpc_created")
    end
  end

  describe "#wait_vpc_created" do
    before do
      client.stub_responses(:modify_vpc_attribute)
      client.stub_responses(:create_security_group, group_id: "sg-0123456789abcdefg")
      client.stub_responses(:authorize_security_group_ingress)
    end

    it "checks if vpc is available, if not naps" do
      client.stub_responses(:describe_vpcs, vpcs: [{state: "pending", vpc_id: "vpc-0123456789abcdefg"}])
      expect { nx.wait_vpc_created }.to nap(1)
    end

    it "creates a security group and authorizes ingress" do
      client.stub_responses(:describe_vpcs, vpcs: [{state: "available", vpc_id: "vpc-0123456789abcdefg"}])

      expect(client).to receive(:describe_vpcs).with({filters: [{name: "vpc-id", values: ["vpc-0123456789abcdefg"]}]}).and_call_original
      expect(client).to receive(:create_security_group).with({group_name: "aws-us-west-2-#{ps.ubid}", description: "Security group for aws-us-west-2-#{ps.ubid}", vpc_id: "vpc-0123456789abcdefg", tag_specifications: Util.aws_tag_specifications("security-group", ps.name)}).and_call_original
      ps.firewalls.map { it.firewall_rules.map { |fw| fw.destroy } }
      FirewallRule.create(firewall_id: ps.firewalls.first.id, cidr: "0.0.0.1/32", port_range: 22..80)
      ps.reload
      expect(ps.private_subnet_aws_resource).to receive(:vpc_id).and_return("vpc-0123456789abcdefg").at_least(:once)
      expect(client).to receive(:authorize_security_group_ingress).with({group_id: "sg-0123456789abcdefg", ip_permissions: [{ip_protocol: "tcp", from_port: 22, to_port: 80, ip_ranges: [{cidr_ip: "0.0.0.1/32"}]}]}).and_call_original
      expect(client).to receive(:authorize_security_group_ingress).with({group_id: "sg-0123456789abcdefg", ip_permissions: [{ip_protocol: "tcp", from_port: 22, to_port: 22, ip_ranges: [{cidr_ip: "0.0.0.0/0"}]}]}).and_call_original
      expect { nx.wait_vpc_created }.to hop("create_route_table")
    end

    it "does not create a security group if it already exists" do
      client.stub_responses(:describe_vpcs, vpcs: [{state: "available", vpc_id: "vpc-0123456789abcdefg"}])
      client.stub_responses(:create_security_group, Aws::EC2::Errors::InvalidGroupDuplicate.new(nil, nil))
      client.stub_responses(:describe_security_groups, security_groups: [{group_id: "sg-0123456789abcdefg"}])

      ps.firewalls.map { it.firewall_rules.map { |fw| fw.destroy } }
      FirewallRule.create(firewall_id: ps.firewalls.first.id, cidr: "0.0.0.1/32", port_range: 22..80)
      FirewallRule.create(firewall_id: ps.firewalls.first.id, cidr: "::/32", port_range: 22..80)
      ps.reload
      expect { nx.wait_vpc_created }.to hop("create_route_table")
    end

    it "skips security group ingress rule if it already exists" do
      client.stub_responses(:describe_vpcs, vpcs: [{state: "available", vpc_id: "vpc-0123456789abcdefg"}])
      client.stub_responses(:authorize_security_group_ingress, Aws::EC2::Errors::InvalidPermissionDuplicate.new(nil, nil), Aws::EC2::Errors::InvalidPermissionDuplicate.new(nil, nil))

      ps.firewalls.map { it.firewall_rules.map { |fw| fw.destroy } }
      FirewallRule.create(firewall_id: ps.firewalls.first.id, cidr: "0.0.0.1/32", port_range: 22..80)
      ps.reload
      expect { nx.wait_vpc_created }.to hop("create_route_table")
    end
  end

  describe "#create_route_table" do
    it "creates a route table with new internet gateway" do
      client.stub_responses(:describe_route_tables, route_tables: [{route_table_id: "rtb-0123456789abcdefg", associations: []}])
      client.stub_responses(:describe_internet_gateways, internet_gateways: [])
      client.stub_responses(:create_internet_gateway, internet_gateway: {internet_gateway_id: "igw-0123456789abcdefg"})
      client.stub_responses(:create_route)
      client.stub_responses(:attach_internet_gateway)
      client.stub_responses(:associate_route_table)
      expect(ps.private_subnet_aws_resource).to receive(:update).with(internet_gateway_id: "igw-0123456789abcdefg")
      expect(ps.private_subnet_aws_resource).to receive(:update).with(route_table_id: "rtb-0123456789abcdefg")
      expect(ps.private_subnet_aws_resource).to receive(:vpc_id).and_return("vpc-0123456789abcdefg").at_least(:once)
      expect(client).to receive(:attach_internet_gateway).with({internet_gateway_id: "igw-0123456789abcdefg", vpc_id: "vpc-0123456789abcdefg"}).and_call_original
      expect(client).to receive(:create_route).with({route_table_id: "rtb-0123456789abcdefg", destination_ipv_6_cidr_block: "::/0", gateway_id: "igw-0123456789abcdefg"}).and_call_original
      expect(client).to receive(:create_route).with({route_table_id: "rtb-0123456789abcdefg", destination_cidr_block: "0.0.0.0/0", gateway_id: "igw-0123456789abcdefg"}).and_call_original
      expect { nx.create_route_table }.to hop("wait")
    end

    it "reuses existing internet gateway and attaches if needed" do
      client.stub_responses(:describe_route_tables, route_tables: [{route_table_id: "rtb-0123456789abcdefg", associations: []}])
      client.stub_responses(:describe_internet_gateways, internet_gateways: [{internet_gateway_id: "igw-existing", attachments: []}])
      client.stub_responses(:create_route)
      client.stub_responses(:attach_internet_gateway)
      client.stub_responses(:associate_route_table)
      expect(client).not_to receive(:create_internet_gateway)
      expect(ps.private_subnet_aws_resource).to receive(:update).with(internet_gateway_id: "igw-existing")
      expect(ps.private_subnet_aws_resource).to receive(:update).with(route_table_id: "rtb-0123456789abcdefg")
      expect(ps.private_subnet_aws_resource).to receive(:vpc_id).and_return("vpc-0123456789abcdefg").at_least(:once)
      expect(client).to receive(:attach_internet_gateway).with({internet_gateway_id: "igw-existing", vpc_id: "vpc-0123456789abcdefg"}).and_call_original
      expect(client).to receive(:create_route).with({route_table_id: "rtb-0123456789abcdefg", destination_ipv_6_cidr_block: "::/0", gateway_id: "igw-existing"}).and_call_original
      expect(client).to receive(:create_route).with({route_table_id: "rtb-0123456789abcdefg", destination_cidr_block: "0.0.0.0/0", gateway_id: "igw-existing"}).and_call_original
      expect { nx.create_route_table }.to hop("wait")
    end

    it "reuses existing internet gateway and skips attachment if already attached" do
      client.stub_responses(:describe_route_tables, route_tables: [{route_table_id: "rtb-0123456789abcdefg", associations: []}])
      client.stub_responses(:describe_internet_gateways, internet_gateways: [{internet_gateway_id: "igw-existing", attachments: [{vpc_id: "vpc-0123456789abcdefg"}]}])
      client.stub_responses(:create_route)
      client.stub_responses(:associate_route_table)
      expect(client).not_to receive(:create_internet_gateway)
      expect(client).not_to receive(:attach_internet_gateway)
      expect(ps.private_subnet_aws_resource).to receive(:update).with(internet_gateway_id: "igw-existing")
      expect(ps.private_subnet_aws_resource).to receive(:update).with(route_table_id: "rtb-0123456789abcdefg")
      expect(ps.private_subnet_aws_resource).to receive(:vpc_id).and_return("vpc-0123456789abcdefg").at_least(:once)
      expect(client).to receive(:create_route).with({route_table_id: "rtb-0123456789abcdefg", destination_ipv_6_cidr_block: "::/0", gateway_id: "igw-existing"}).and_call_original
      expect(client).to receive(:create_route).with({route_table_id: "rtb-0123456789abcdefg", destination_cidr_block: "0.0.0.0/0", gateway_id: "igw-existing"}).and_call_original
      expect { nx.create_route_table }.to hop("wait")
    end

    it "omits if the route already exists" do
      client.stub_responses(:describe_route_tables, route_tables: [{route_table_id: "rtb-0123456789abcdefg", associations: []}])
      client.stub_responses(:describe_internet_gateways, internet_gateways: [])
      client.stub_responses(:create_internet_gateway, internet_gateway: {internet_gateway_id: "igw-0123456789abcdefg"})
      client.stub_responses(:create_route, Aws::EC2::Errors::RouteAlreadyExists.new(nil, nil))
      client.stub_responses(:attach_internet_gateway)
      expect(client).to receive(:describe_route_tables).with({filters: [{name: "vpc-id", values: ["vpc-0123456789abcdefg"]}]}).and_call_original
      expect(ps.private_subnet_aws_resource).to receive(:update).with(internet_gateway_id: "igw-0123456789abcdefg")
      expect(ps.private_subnet_aws_resource).to receive(:update).with(route_table_id: "rtb-0123456789abcdefg")
      expect(ps.private_subnet_aws_resource).to receive(:vpc_id).and_return("vpc-0123456789abcdefg").at_least(:once)
      expect(client).to receive(:attach_internet_gateway).with({internet_gateway_id: "igw-0123456789abcdefg", vpc_id: "vpc-0123456789abcdefg"}).and_call_original
      expect(client).to receive(:create_route).with({route_table_id: "rtb-0123456789abcdefg", destination_ipv_6_cidr_block: "::/0", gateway_id: "igw-0123456789abcdefg"}).and_call_original
      expect { nx.create_route_table }.to hop("wait")
    end

    it "skips route table association if already associated" do
      client.stub_responses(:describe_route_tables, route_tables: [{route_table_id: "rtb-0123456789abcdefg", associations: [{subnet_id: "subnet-existing"}]}])
      client.stub_responses(:describe_internet_gateways, internet_gateways: [])
      client.stub_responses(:create_internet_gateway, internet_gateway: {internet_gateway_id: "igw-0123456789abcdefg"})
      client.stub_responses(:create_route)
      client.stub_responses(:attach_internet_gateway)
      expect(client).not_to receive(:associate_route_table)
      expect(ps.private_subnet_aws_resource).to receive(:update).with(internet_gateway_id: "igw-0123456789abcdefg")
      expect(ps.private_subnet_aws_resource).to receive(:update).with(route_table_id: "rtb-0123456789abcdefg")
      expect(ps.private_subnet_aws_resource).to receive(:vpc_id).and_return("vpc-0123456789abcdefg").at_least(:once)
      expect(client).to receive(:attach_internet_gateway).with({internet_gateway_id: "igw-0123456789abcdefg", vpc_id: "vpc-0123456789abcdefg"}).and_call_original
      expect(client).to receive(:create_route).with({route_table_id: "rtb-0123456789abcdefg", destination_ipv_6_cidr_block: "::/0", gateway_id: "igw-0123456789abcdefg"}).and_call_original
      expect(client).to receive(:create_route).with({route_table_id: "rtb-0123456789abcdefg", destination_cidr_block: "0.0.0.0/0", gateway_id: "igw-0123456789abcdefg"}).and_call_original
      expect { nx.create_route_table }.to hop("wait")
    end
  end

  describe "#wait" do
    it "increments update_firewall_rules on vms if update_firewall_rules is set" do
      expect(nx).to receive(:when_update_firewall_rules_set?).and_yield
      expect(ps).to receive(:vms).and_return([instance_double(Vm)]).at_least(:once)
      vm = ps.vms.first
      expect(vm).to receive(:incr_update_firewall_rules)
      expect(nx).to receive(:decr_update_firewall_rules)
      expect { nx.wait }.to nap(60 * 60 * 24 * 365)
    end
  end

  describe "#destroy" do
    before do
      ps.private_subnet_aws_resource.update(security_group_id: "sg-0123456789abcdefg", internet_gateway_id: "igw-0123456789abcdefg")
      client.stub_responses(:describe_subnets, subnets: [{state: "available"}])
    end

    let(:nic) {
      instance_double(Nic, vm_id: nil)
    }

    it "extends deadline if a vm prevents destroy" do
      vm = Vm.new(family: "standard", cores: 1, name: "dummy-vm", location_id: Location::HETZNER_FSN1_ID).tap {
        it.id = "788525ed-d6f0-4937-a844-323d4fd91946"
      }
      expect(ps).to receive(:nics).and_return([nic]).twice
      expect(nic).to receive(:vm_id).and_return("vm-id")
      expect(nic).to receive(:vm).and_return(vm)
      expect(vm).to receive(:prevent_destroy_set?).and_return(true)
      expect(nx).to receive(:register_deadline).with(nil, 10 * 60, allow_extension: true)

      expect { nx.destroy }.to nap(5)
    end

    it "fails if there are active resources" do
      expect(ps).to receive(:nics).and_return([nic]).twice
      expect(nic).to receive(:vm_id).and_return("vm-id")
      expect(nic).to receive(:vm).and_return(nil)
      expect(Clog).to receive(:emit).with("Cannot destroy subnet with active nics, first clean up the attached resources").and_call_original

      expect { nx.destroy }.to nap(5)
    end

    it "deletes the security group and hops to delete_internet_gateway" do
      client.stub_responses(:delete_security_group)
      expect(client).to receive(:delete_security_group).with({group_id: "sg-0123456789abcdefg"}).and_call_original
      expect { nx.destroy }.to hop("delete_internet_gateway")
    end

    it "hops to delete_internet_gateway if security group is not found" do
      client.stub_responses(:delete_security_group, Aws::EC2::Errors::InvalidGroupNotFound.new(nil, nil))
      expect { nx.destroy }.to hop("delete_internet_gateway")
    end

    describe "#delete_internet_gateway" do
      it "deletes the internet gateway and hops to delete_vpc" do
        client.stub_responses(:delete_internet_gateway)
        client.stub_responses(:detach_internet_gateway)
        expect(ps.private_subnet_aws_resource).to receive(:vpc_id).and_return("vpc-0123456789abcdefg")
        expect(client).to receive(:delete_internet_gateway).with({internet_gateway_id: "igw-0123456789abcdefg"}).and_call_original
        expect(client).to receive(:detach_internet_gateway).with({internet_gateway_id: "igw-0123456789abcdefg", vpc_id: "vpc-0123456789abcdefg"}).and_call_original
        expect { nx.delete_internet_gateway }.to hop("delete_vpc")
      end

      it "hops to delete_vpc if internet gateway is not found" do
        client.stub_responses(:delete_internet_gateway, Aws::EC2::Errors::InvalidInternetGatewayIDNotFound.new(nil, nil))
        client.stub_responses(:detach_internet_gateway)
        expect(ps.private_subnet_aws_resource).to receive(:vpc_id).and_return("vpc-0123456789abcdefg")
        expect { nx.delete_internet_gateway }.to hop("delete_vpc")
      end
    end

    describe "#delete_vpc" do
      it "deletes the vpc" do
        client.stub_responses(:delete_vpc)
        expect(ps.private_subnet_aws_resource).to receive(:vpc_id).and_return("vpc-0123456789abcdefg")
        expect(client).to receive(:delete_vpc).with({vpc_id: "vpc-0123456789abcdefg"}).and_call_original
        expect { nx.delete_vpc }.to exit({"msg" => "vpc destroyed"})
      end

      it "naps if there are nics" do
        expect(nx).to receive(:private_subnet).and_return(ps).at_least(:once)
        expect(ps).to receive(:nics).and_return([1]).at_least(:once)
        expect { nx.delete_vpc }.to nap(5)
      end

      it "pops if vpc is not found" do
        client.stub_responses(:delete_vpc, Aws::EC2::Errors::InvalidVpcIDNotFound.new(nil, nil))
        expect(ps.private_subnet_aws_resource).to receive(:vpc_id).and_return("vpc-0123456789abcdefg")
        expect { nx.delete_vpc }.to exit({"msg" => "vpc destroyed"})
      end
    end
  end
end
