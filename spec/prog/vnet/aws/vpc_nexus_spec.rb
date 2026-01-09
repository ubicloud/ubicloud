# frozen_string_literal: true

RSpec.describe Prog::Vnet::Aws::VpcNexus do
  subject(:nx) { described_class.new(ps.strand) }

  let(:ps) {
    prj = Project.create(name: "test-prj")
    loc = Location.create(name: "us-west-2", provider: "aws", project_id: prj.id, display_name: "aws-us-west-2", ui_name: "AWS US East 1", visible: true)
    LocationCredential.create_with_id(loc.id, access_key: "stubbed-akid", secret_key: "stubbed-secret")
    ps = Prog::Vnet::SubnetNexus.assemble(prj.id, name: "test-ps", location_id: loc.id).subject
    PrivateSubnetAwsResource.create_with_id(ps.id, vpc_id: "vpc-0123456789abcdefg", internet_gateway_id: "igw-0123456789abcdefg", route_table_id: "rtb-0123456789abcdefg", security_group_id: "sg-0123456789abcdefg")
    ps
  }

  let(:location) { ps.location }
  let(:client) { Aws::EC2::Client.new(stub_responses: true) }
  let(:aws_resource) { nx.private_subnet.private_subnet_aws_resource }

  before do
    aws_credentials = Aws::Credentials.new("stubbed-akid", "stubbed-secret")
    allow(Aws::Credentials).to receive(:new).with("stubbed-akid", "stubbed-secret").and_return(aws_credentials)
    allow(Aws::EC2::Client).to receive(:new).with(credentials: aws_credentials, region: "us-west-2").and_return(client)
  end

  describe "#start" do
    it "creates PrivateSubnetAwsResource and hops to create_vpc" do
      aws_resource.destroy
      expect { nx.start }.to hop("create_vpc")
      expect(ps.private_subnet_aws_resource).not_to be_nil
    end
  end

  describe "#create_vpc" do
    before { aws_resource.update(vpc_id: nil) }

    it "creates a vpc" do
      client.stub_responses(:describe_vpcs, vpcs: [])
      client.stub_responses(:create_vpc, vpc: {vpc_id: "vpc-0123456789abcdefg"})
      expect(client).to receive(:create_vpc).with({cidr_block: ps.net4.to_s, amazon_provided_ipv_6_cidr_block: true, tag_specifications: Util.aws_tag_specifications("vpc", ps.name)}).and_call_original
      expect { nx.create_vpc }.to hop("wait_vpc_created")
        .and change { aws_resource.reload.vpc_id }.from(nil).to("vpc-0123456789abcdefg")
    end

    it "reuses existing vpc" do
      client.stub_responses(:describe_vpcs, vpcs: [{vpc_id: "vpc-existing"}])
      expect(client).not_to receive(:create_vpc)
      expect { nx.create_vpc }.to hop("wait_vpc_created")
        .and change { aws_resource.reload.vpc_id }.from(nil).to("vpc-existing")
    end
  end

  describe "#wait_vpc_created" do
    before do
      client.stub_responses(:modify_vpc_attribute)
      client.stub_responses(:create_security_group, group_id: "sg-0123456789abcdefg")
      client.stub_responses(:authorize_security_group_ingress)
      ps.firewalls.each { it.firewall_rules.each(&:destroy) }
      ps.reload
    end

    it "checks if vpc is available, if not naps" do
      client.stub_responses(:describe_vpcs, vpcs: [{state: "pending", vpc_id: "vpc-0123456789abcdefg"}])
      expect { nx.wait_vpc_created }.to nap(1)
    end

    it "creates a security group and authorizes ingress" do
      client.stub_responses(:describe_vpcs, vpcs: [{state: "available", vpc_id: "vpc-0123456789abcdefg"}])
      expect(client).to receive(:describe_vpcs).with({filters: [{name: "vpc-id", values: ["vpc-0123456789abcdefg"]}]}).and_call_original
      expect(client).to receive(:create_security_group).with({group_name: "aws-us-west-2-#{ps.ubid}", description: "Security group for aws-us-west-2-#{ps.ubid}", vpc_id: "vpc-0123456789abcdefg", tag_specifications: Util.aws_tag_specifications("security-group", ps.name)}).and_call_original
      expect(client).to receive(:authorize_security_group_ingress).with({group_id: "sg-0123456789abcdefg", ip_permissions: [{ip_protocol: "tcp", from_port: 22, to_port: 80, ip_ranges: [{cidr_ip: "0.0.0.1/32"}]}]}).and_call_original
      expect(client).to receive(:authorize_security_group_ingress).with({group_id: "sg-0123456789abcdefg", ip_permissions: [{ip_protocol: "tcp", from_port: 22, to_port: 22, ip_ranges: [{cidr_ip: "0.0.0.0/0"}]}]}).and_call_original
      FirewallRule.create(firewall_id: ps.firewalls.first.id, cidr: "0.0.0.1/32", port_range: 22..80)
      expect { nx.wait_vpc_created }.to hop("create_route_table")
    end

    it "does not create a security group if it already exists" do
      client.stub_responses(:describe_vpcs, vpcs: [{state: "available", vpc_id: "vpc-0123456789abcdefg"}])
      client.stub_responses(:create_security_group, Aws::EC2::Errors::InvalidGroupDuplicate.new(nil, nil))
      client.stub_responses(:describe_security_groups, security_groups: [{group_id: "sg-0123456789abcdefg"}])
      FirewallRule.create(firewall_id: ps.firewalls.first.id, cidr: "0.0.0.1/32", port_range: 22..80)
      FirewallRule.create(firewall_id: ps.firewalls.first.id, cidr: "::/32", port_range: 22..80)
      expect { nx.wait_vpc_created }.to hop("create_route_table")
    end

    it "skips security group ingress rule if it already exists" do
      client.stub_responses(:describe_vpcs, vpcs: [{state: "available", vpc_id: "vpc-0123456789abcdefg"}])
      client.stub_responses(:authorize_security_group_ingress, Aws::EC2::Errors::InvalidPermissionDuplicate.new(nil, nil), Aws::EC2::Errors::InvalidPermissionDuplicate.new(nil, nil))
      FirewallRule.create(firewall_id: ps.firewalls.first.id, cidr: "0.0.0.1/32", port_range: 22..80)
      expect { nx.wait_vpc_created }.to hop("create_route_table")
    end
  end

  describe "#create_route_table" do
    before { aws_resource.update(internet_gateway_id: nil, route_table_id: nil) }

    it "creates a route table with new internet gateway" do
      client.stub_responses(:describe_route_tables, route_tables: [{route_table_id: "rtb-0123456789abcdefg", associations: []}])
      client.stub_responses(:describe_internet_gateways, internet_gateways: [])
      client.stub_responses(:create_internet_gateway, internet_gateway: {internet_gateway_id: "igw-0123456789abcdefg"})
      client.stub_responses(:create_route)
      client.stub_responses(:attach_internet_gateway)
      client.stub_responses(:associate_route_table)
      expect(client).to receive(:attach_internet_gateway).with({internet_gateway_id: "igw-0123456789abcdefg", vpc_id: "vpc-0123456789abcdefg"}).and_call_original
      expect(client).to receive(:create_route).with({route_table_id: "rtb-0123456789abcdefg", destination_ipv_6_cidr_block: "::/0", gateway_id: "igw-0123456789abcdefg"}).and_call_original
      expect(client).to receive(:create_route).with({route_table_id: "rtb-0123456789abcdefg", destination_cidr_block: "0.0.0.0/0", gateway_id: "igw-0123456789abcdefg"}).and_call_original
      expect { nx.create_route_table }.to hop("wait")
        .and change { aws_resource.reload.internet_gateway_id }.from(nil).to("igw-0123456789abcdefg")
        .and change { aws_resource.reload.route_table_id }.from(nil).to("rtb-0123456789abcdefg")
    end

    it "reuses existing internet gateway and attaches if needed" do
      client.stub_responses(:describe_route_tables, route_tables: [{route_table_id: "rtb-0123456789abcdefg", associations: []}])
      client.stub_responses(:describe_internet_gateways, internet_gateways: [{internet_gateway_id: "igw-existing", attachments: []}])
      client.stub_responses(:create_route)
      client.stub_responses(:attach_internet_gateway)
      client.stub_responses(:associate_route_table)
      expect(client).not_to receive(:create_internet_gateway)
      expect(client).to receive(:attach_internet_gateway).with({internet_gateway_id: "igw-existing", vpc_id: "vpc-0123456789abcdefg"}).and_call_original
      expect(client).to receive(:create_route).with({route_table_id: "rtb-0123456789abcdefg", destination_ipv_6_cidr_block: "::/0", gateway_id: "igw-existing"}).and_call_original
      expect(client).to receive(:create_route).with({route_table_id: "rtb-0123456789abcdefg", destination_cidr_block: "0.0.0.0/0", gateway_id: "igw-existing"}).and_call_original
      expect { nx.create_route_table }.to hop("wait")
        .and change { aws_resource.reload.internet_gateway_id }.from(nil).to("igw-existing")
        .and change { aws_resource.reload.route_table_id }.from(nil).to("rtb-0123456789abcdefg")
    end

    it "reuses existing internet gateway and skips attachment if already attached" do
      client.stub_responses(:describe_route_tables, route_tables: [{route_table_id: "rtb-0123456789abcdefg", associations: []}])
      client.stub_responses(:describe_internet_gateways, internet_gateways: [{internet_gateway_id: "igw-existing", attachments: [{vpc_id: "vpc-0123456789abcdefg"}]}])
      client.stub_responses(:create_route)
      client.stub_responses(:associate_route_table)
      expect(client).not_to receive(:create_internet_gateway)
      expect(client).not_to receive(:attach_internet_gateway)
      expect(client).to receive(:create_route).with({route_table_id: "rtb-0123456789abcdefg", destination_ipv_6_cidr_block: "::/0", gateway_id: "igw-existing"}).and_call_original
      expect(client).to receive(:create_route).with({route_table_id: "rtb-0123456789abcdefg", destination_cidr_block: "0.0.0.0/0", gateway_id: "igw-existing"}).and_call_original
      expect { nx.create_route_table }.to hop("wait")
        .and change { aws_resource.reload.internet_gateway_id }.from(nil).to("igw-existing")
        .and change { aws_resource.reload.route_table_id }.from(nil).to("rtb-0123456789abcdefg")
    end

    it "omits if the route already exists" do
      client.stub_responses(:describe_route_tables, route_tables: [{route_table_id: "rtb-0123456789abcdefg", associations: []}])
      client.stub_responses(:describe_internet_gateways, internet_gateways: [])
      client.stub_responses(:create_internet_gateway, internet_gateway: {internet_gateway_id: "igw-0123456789abcdefg"})
      client.stub_responses(:create_route, Aws::EC2::Errors::RouteAlreadyExists.new(nil, nil))
      client.stub_responses(:attach_internet_gateway)
      expect(client).to receive(:describe_route_tables).with({filters: [{name: "vpc-id", values: ["vpc-0123456789abcdefg"]}]}).and_call_original
      expect(client).to receive(:attach_internet_gateway).with({internet_gateway_id: "igw-0123456789abcdefg", vpc_id: "vpc-0123456789abcdefg"}).and_call_original
      expect(client).to receive(:create_route).with({route_table_id: "rtb-0123456789abcdefg", destination_ipv_6_cidr_block: "::/0", gateway_id: "igw-0123456789abcdefg"}).and_call_original
      expect { nx.create_route_table }.to hop("wait")
        .and change { aws_resource.reload.internet_gateway_id }.from(nil).to("igw-0123456789abcdefg")
        .and change { aws_resource.reload.route_table_id }.from(nil).to("rtb-0123456789abcdefg")
    end

    it "skips route table association if already associated" do
      client.stub_responses(:describe_route_tables, route_tables: [{route_table_id: "rtb-0123456789abcdefg", associations: [{subnet_id: "subnet-existing"}]}])
      client.stub_responses(:describe_internet_gateways, internet_gateways: [])
      client.stub_responses(:create_internet_gateway, internet_gateway: {internet_gateway_id: "igw-0123456789abcdefg"})
      client.stub_responses(:create_route)
      client.stub_responses(:attach_internet_gateway)
      expect(client).not_to receive(:associate_route_table)
      expect(client).to receive(:attach_internet_gateway).with({internet_gateway_id: "igw-0123456789abcdefg", vpc_id: "vpc-0123456789abcdefg"}).and_call_original
      expect(client).to receive(:create_route).with({route_table_id: "rtb-0123456789abcdefg", destination_ipv_6_cidr_block: "::/0", gateway_id: "igw-0123456789abcdefg"}).and_call_original
      expect(client).to receive(:create_route).with({route_table_id: "rtb-0123456789abcdefg", destination_cidr_block: "0.0.0.0/0", gateway_id: "igw-0123456789abcdefg"}).and_call_original
      expect { nx.create_route_table }.to hop("wait")
        .and change { aws_resource.reload.internet_gateway_id }.from(nil).to("igw-0123456789abcdefg")
        .and change { aws_resource.reload.route_table_id }.from(nil).to("rtb-0123456789abcdefg")
    end
  end

  describe "#wait" do
    it "increments update_firewall_rules on vms if update_firewall_rules is set" do
      nx.incr_update_firewall_rules
      vm = create_hosted_vm(ps.project, ps, "vm1")
      expect { nx.wait }.to nap(60 * 60 * 24 * 365)
      expect(vm.update_firewall_rules_set?).to be true
      expect(ps.update_firewall_rules_set?).to be false
    end
  end

  describe "#destroy" do
    before {
      allow(Clog).to receive(:emit).and_call_original
      client.stub_responses(:describe_subnets, subnets: [{state: "available"}])
    }

    it "extends deadline if a vm prevents destroy" do
      vm = create_hosted_vm(ps.project, ps, "vm1")
      vm.incr_prevent_destroy

      expect { nx.destroy }.to nap(5)
      expect(nx.strand.stack.first["deadline_at"]).to be_within(5).of(Time.now + 10 * 60)
      expect(nx.strand.stack.first.fetch("deadline_target")).to be_nil
    end

    it "fails if there are active resources" do
      vm = create_hosted_vm(ps.project, ps, "vm1")
      create_hosted_vm(ps.project, ps, "vm2")
      vm.nic.update(vm_id: nil)
      expect(Clog).to receive(:emit).with("Cannot destroy subnet with active nics, first clean up the attached resources", instance_of(PrivateSubnet)).and_call_original

      expect { nx.destroy }.to nap(5)
    end

    it "hops to finish if aws resource not exists" do
      aws_resource.destroy
      nx.private_subnet.reload
      expect { nx.destroy }.to hop("finish")
    end

    it "deletes the security group and hops to delete_internet_gateway" do
      client.stub_responses(:delete_security_group)
      expect(client).to receive(:delete_security_group).with({group_id: "sg-0123456789abcdefg"}).and_call_original
      expect { nx.destroy }.to hop("delete_internet_gateway")
    end

    it "naps if security group is in use" do
      client.stub_responses(:delete_security_group, Aws::EC2::Errors::DependencyViolation.new(nil, "resource sg-0123456789abcdefg has a dependent object"))
      expect(Clog).to receive(:emit).with("Security group is in use", instance_of(Hash)).and_call_original
      expect { nx.destroy }.to nap(5)
    end

    it "raises an error if security group could not be deleted" do
      client.stub_responses(:delete_security_group, Aws::EC2::Errors::DependencyViolation.new(nil, "Unrelated error"))
      expect { nx.destroy }.to raise_error(Aws::EC2::Errors::DependencyViolation, "Unrelated error")
    end

    it "hops to delete_internet_gateway if security group is not found" do
      client.stub_responses(:delete_security_group, Aws::EC2::Errors::InvalidGroupNotFound.new(nil, nil))
      expect { nx.destroy }.to hop("delete_internet_gateway")
    end

    describe "#delete_internet_gateway" do
      it "deletes the internet gateway and hops to delete_vpc" do
        client.stub_responses(:delete_internet_gateway)
        client.stub_responses(:detach_internet_gateway)
        expect(client).to receive(:delete_internet_gateway).with({internet_gateway_id: "igw-0123456789abcdefg"}).and_call_original
        expect(client).to receive(:detach_internet_gateway).with({internet_gateway_id: "igw-0123456789abcdefg", vpc_id: "vpc-0123456789abcdefg"}).and_call_original
        expect { nx.delete_internet_gateway }.to hop("delete_vpc")
      end

      it "hops to delete_vpc if internet gateway is not found" do
        client.stub_responses(:delete_internet_gateway, Aws::EC2::Errors::InvalidInternetGatewayIDNotFound.new(nil, nil))
        client.stub_responses(:detach_internet_gateway)
        expect { nx.delete_internet_gateway }.to hop("delete_vpc")
      end
    end

    describe "#delete_vpc" do
      it "deletes the vpc" do
        client.stub_responses(:delete_vpc)
        expect(client).to receive(:delete_vpc).with({vpc_id: "vpc-0123456789abcdefg"}).and_call_original
        expect { nx.delete_vpc }.to hop("finish")
      end

      it "hops if vpc is not found" do
        client.stub_responses(:delete_vpc, Aws::EC2::Errors::InvalidVpcIDNotFound.new(nil, nil))
        expect { nx.delete_vpc }.to hop("finish")
      end
    end

    describe "#finish" do
      it "naps if there are nics" do
        create_hosted_vm(ps.project, ps, "vm1")
        expect { nx.finish }.to nap(5)
      end

      it "pops after destroying resources" do
        expect { nx.finish }.to exit({"msg" => "vpc destroyed"})
        expect(ps.exists?).to be false
        expect(aws_resource.exists?).to be false
      end

      it "pops even aws resource not exists" do
        aws_resource.destroy
        nx.private_subnet.reload
        expect(aws_resource.exists?).to be false
        expect { nx.finish }.to exit({"msg" => "vpc destroyed"})
        expect(ps.exists?).to be false
      end
    end
  end
end
