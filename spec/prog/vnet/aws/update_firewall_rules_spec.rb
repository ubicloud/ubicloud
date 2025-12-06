# frozen_string_literal: true

RSpec.describe Prog::Vnet::Aws::UpdateFirewallRules do
  subject(:nx) {
    described_class.new(st)
  }

  let(:st) { Strand.new }
  let(:ps) {
    instance_double(PrivateSubnet)
  }
  let(:vm) {
    vmh = instance_double(VmHost, sshable: Sshable.new)
    nic = instance_double(Nic, private_ipv4: NetAddr::IPv4Net.parse("10.0.0.0/32"), private_ipv6: NetAddr::IPv6Net.parse("fd00::1/128"), ubid_to_tap_name: "tap0")
    ephemeral_net6 = NetAddr::IPv6Net.parse("fd00::1/79")
    location = Location.create(name: "us-west-2", provider: "aws", display_name: "aws-us-west-2", ui_name: "AWS US East 1", visible: true)
    instance_double(Vm, project: instance_double(Project, get_ff_ipv6_disabled: false), private_subnets: [ps], vm_host: vmh, inhost_name: "x", nics: [nic], ephemeral_net6: ephemeral_net6, load_balancer: nil, private_ipv4: NetAddr::IPv4Net.parse("10.0.0.0/32").network, location: location.id)
  }

  describe "#before_run" do
    it "pops if vm is to be destroyed" do
      expect(nx).to receive(:vm).and_return(vm).at_least(:once)
      expect(vm).to receive(:destroy_set?).and_return(true)
      expect { nx.before_run }.to exit({"msg" => "firewall rule is added"})
    end

    it "does not pop if vm is not to be destroyed" do
      expect(nx).to receive(:vm).and_return(vm).at_least(:once)
      expect(vm).to receive(:destroy_set?).and_return(false)
      expect { nx.before_run }.not_to exit
    end
  end

  describe "update_firewall_rules" do
    let(:ec2_client) { instance_double(Aws::EC2::Client) }

    before do
      lcred = instance_double(LocationCredential, client: ec2_client)
      loc = instance_double(Location, provider: "aws", location_credential: lcred)
      allow(nx).to receive(:vm).and_return(vm)
      allow(vm).to receive(:location).and_return(loc)
    end

    it "hops to remove_aws_firewall_rules if there are no fw rules to add" do
      expect(nx).to receive(:vm).and_return(vm).at_least(:once)
      expect(vm).to receive(:firewall_rules).and_return([])
      expect { nx.update_firewall_rules }.to hop("remove_aws_old_rules")
    end

    it "hops to remove_aws_firewall_rules after adding new rules" do
      expect(nx).to receive(:vm).and_return(vm).at_least(:once)
      expect(vm).to receive(:firewall_rules).and_return([
        instance_double(FirewallRule, ip6?: false, cidr: NetAddr::IPv4Net.parse("0.0.0.0/0"), port_range: Sequel.pg_range(80..10000), protocol: "tcp"),
        instance_double(FirewallRule, ip6?: false, cidr: NetAddr::IPv4Net.parse("1.1.1.1/32"), port_range: Sequel.pg_range(22..23), protocol: "tcp"),
        instance_double(FirewallRule, ip6?: true, cidr: NetAddr::IPv6Net.parse("fd00::1/128"), port_range: Sequel.pg_range(80..10000), protocol: "tcp")
      ])
      expect(vm.private_subnets.first).to receive(:private_subnet_aws_resource).and_return(instance_double(PrivateSubnetAwsResource, security_group_id: "sg-1234567890")).at_least(:once)
      expect(ec2_client).to receive(:authorize_security_group_ingress).with({
        group_id: "sg-1234567890",
        ip_permissions: [
          {
            ip_protocol: "tcp",
            from_port: 80,
            to_port: 9999,
            ip_ranges: [{cidr_ip: "0.0.0.0/0"}]
          }
        ]
      })
      expect(ec2_client).to receive(:authorize_security_group_ingress).with({
        group_id: "sg-1234567890",
        ip_permissions: [
          {
            ip_protocol: "tcp",
            from_port: 22,
            to_port: 22,
            ip_ranges: [{cidr_ip: "1.1.1.1/32"}]
          }
        ]
      })
      expect(ec2_client).to receive(:authorize_security_group_ingress).with({
        group_id: "sg-1234567890",
        ip_permissions: [
          {
            ip_protocol: "tcp",
            from_port: 80,
            to_port: 9999,
            ipv_6_ranges: [{cidr_ipv_6: "fd00::1/128"}]
          }
        ]
      })

      expect { nx.update_firewall_rules }.to hop("remove_aws_old_rules")
    end

    it "continues and hops to remove_aws_old_rules if there is a duplicate rule" do
      expect(nx).to receive(:vm).and_return(vm).at_least(:once)
      expect(vm).to receive(:firewall_rules).and_return([
        instance_double(FirewallRule, ip6?: false, cidr: NetAddr::IPv4Net.parse("0.0.0.0/0"), port_range: Sequel.pg_range(80..10000), protocol: "tcp"),
        instance_double(FirewallRule, ip6?: false, cidr: NetAddr::IPv4Net.parse("1.1.1.1/32"), port_range: Sequel.pg_range(22..23), protocol: "tcp"),
        instance_double(FirewallRule, ip6?: true, cidr: NetAddr::IPv6Net.parse("fd00::1/128"), port_range: Sequel.pg_range(80..10000), protocol: "tcp")
      ])
      expect(vm.private_subnets.first).to receive(:private_subnet_aws_resource).and_return(instance_double(PrivateSubnetAwsResource, security_group_id: "sg-1234567890")).at_least(:once)
      expect(ec2_client).to receive(:authorize_security_group_ingress).with({
        group_id: "sg-1234567890",
        ip_permissions: [
          {
            ip_protocol: "tcp",
            from_port: 80,
            to_port: 9999,
            ip_ranges: [{cidr_ip: "0.0.0.0/0"}]
          }
        ]
      }).and_raise(Aws::EC2::Errors::InvalidPermissionDuplicate.new("Duplicate", "Duplicate"))
      expect(ec2_client).to receive(:authorize_security_group_ingress).with({
        group_id: "sg-1234567890",
        ip_permissions: [
          {
            ip_protocol: "tcp",
            from_port: 22,
            to_port: 22,
            ip_ranges: [{cidr_ip: "1.1.1.1/32"}]
          }
        ]
      })
      expect(ec2_client).to receive(:authorize_security_group_ingress).with({
        group_id: "sg-1234567890",
        ip_permissions: [
          {
            ip_protocol: "tcp",
            from_port: 80,
            to_port: 9999,
            ipv_6_ranges: [{cidr_ipv_6: "fd00::1/128"}]
          }
        ]
      })

      expect { nx.update_firewall_rules }.to hop("remove_aws_old_rules")
    end
  end

  describe "#remove_aws_old_rules" do
    let(:ec2_client) { Aws::EC2::Client.new(stub_responses: true) }

    before do
      lcred = instance_double(LocationCredential, client: ec2_client)
      loc = instance_double(Location, provider: "aws", location_credential: lcred)
      allow(nx).to receive(:vm).and_return(vm)
      allow(vm).to receive(:location).and_return(loc)
    end

    it "removes old rules" do
      expect(nx).to receive(:vm).and_return(vm).at_least(:once)
      expect(vm).to receive(:firewall_rules).and_return([
        instance_double(FirewallRule, ip6?: false, cidr: NetAddr::IPv4Net.parse("0.0.0.0/0"), port_range: Sequel.pg_range(80..10000), protocol: "tcp"),
        instance_double(FirewallRule, ip6?: false, cidr: NetAddr::IPv4Net.parse("1.1.1.1/32"), port_range: Sequel.pg_range(22..23), protocol: "tcp"),
        instance_double(FirewallRule, ip6?: true, cidr: NetAddr::IPv6Net.parse("fd00::1/128"), port_range: Sequel.pg_range(80..10000), protocol: "tcp")
      ])
      expect(vm.private_subnets.first).to receive(:private_subnet_aws_resource).and_return(instance_double(PrivateSubnetAwsResource, security_group_id: "sg-1234567890")).at_least(:once)
      ec2_client.stub_responses(:describe_security_groups, security_groups: [ip_permissions: [
        {
          ip_protocol: "tcp",
          from_port: 0,
          to_port: 100,
          ip_ranges: [],
          ipv_6_ranges: [{cidr_ipv_6: "fd00::1/128"}]
        },
        {
          ip_protocol: "udp",
          from_port: 0,
          to_port: 100,
          ip_ranges: [{cidr_ip: "0.0.0.0/0"}],
          ipv_6_ranges: [{cidr_ipv_6: "fd00::1/128"}]
        },
        {
          ip_protocol: "tcp",
          from_port: 0,
          to_port: 100,
          ip_ranges: [{cidr_ip: "10.10.10.10/32"}],
          ipv_6_ranges: []
        },
        {
          ip_protocol: "tcp",
          from_port: 80,
          to_port: 9999,
          ip_ranges: [],
          ipv_6_ranges: [{cidr_ipv_6: "fd00::1/128"}]
        },
        {
          ip_protocol: "tcp",
          from_port: 80,
          to_port: 9999,
          ip_ranges: [{cidr_ip: "0.0.0.0/0"}],
          ipv_6_ranges: []
        }
      ]])

      expect(ec2_client).to receive(:revoke_security_group_ingress).with({group_id: "sg-1234567890", ip_permissions: [{from_port: 0, ip_protocol: "udp", ip_ranges: [Aws::EC2::Types::IpRange.new(cidr_ip: "0.0.0.0/0")], ipv_6_ranges: [Aws::EC2::Types::Ipv6Range.new(cidr_ipv_6: "fd00::1/128")], to_port: 100}]})
      expect(ec2_client).to receive(:revoke_security_group_ingress).with({group_id: "sg-1234567890", ip_permissions: [{from_port: 0, ip_protocol: "tcp", ipv_6_ranges: [Aws::EC2::Types::Ipv6Range.new(cidr_ipv_6: "fd00::1/128")], to_port: 100}]})
      expect(ec2_client).to receive(:revoke_security_group_ingress).with({group_id: "sg-1234567890", ip_permissions: [{from_port: 0, ip_protocol: "tcp", ip_ranges: [Aws::EC2::Types::IpRange.new(cidr_ip: "10.10.10.10/32")], to_port: 100}]}).and_raise(Aws::EC2::Errors::InvalidPermissionNotFound.new("Duplicate", "Duplicate"))

      expect { nx.remove_aws_old_rules }.to exit({"msg" => "firewall rule is added"})
    end

    it "doesn't make a call if there are no old rules" do
      expect(nx).to receive(:vm).and_return(vm).at_least(:once)
      expect(vm).to receive(:firewall_rules).and_return([
        instance_double(FirewallRule, ip6?: false, cidr: NetAddr::IPv4Net.parse("0.0.0.0/0"), port_range: Sequel.pg_range(80..10000), protocol: "tcp"),
        instance_double(FirewallRule, ip6?: false, cidr: NetAddr::IPv4Net.parse("1.1.1.1/32"), port_range: Sequel.pg_range(22..23), protocol: "tcp"),
        instance_double(FirewallRule, ip6?: true, cidr: NetAddr::IPv6Net.parse("fd00::1/128"), port_range: Sequel.pg_range(80..10000), protocol: "tcp")
      ])
      expect(vm.private_subnets.first).to receive(:private_subnet_aws_resource).and_return(instance_double(PrivateSubnetAwsResource, security_group_id: "sg-1234567890")).at_least(:once)
      ec2_client.stub_responses(:describe_security_groups, security_groups: [ip_permissions: [
        {
          ip_protocol: "tcp",
          from_port: 80,
          to_port: 9999,
          ip_ranges: [{cidr_ip: "0.0.0.0/0"}],
          ipv_6_ranges: [{cidr_ipv_6: "fd00::1/128"}]
        },
        {
          ip_protocol: "tcp",
          from_port: 80,
          to_port: 9999,
          ip_ranges: [{cidr_ip: "0.0.0.0/0"}],
          ipv_6_ranges: []
        }
      ]])
      expect(ec2_client).not_to receive(:revoke_security_group_ingress)

      expect { nx.remove_aws_old_rules }.to exit({"msg" => "firewall rule is added"})
    end
  end
end
