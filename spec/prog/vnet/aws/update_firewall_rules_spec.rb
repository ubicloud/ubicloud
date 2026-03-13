# frozen_string_literal: true

RSpec.describe Prog::Vnet::Aws::UpdateFirewallRules do
  subject(:nx) {
    described_class.new(st)
  }

  let(:project) { Project.create(name: "test-project") }
  let(:location) {
    Location.create(name: "us-west-2", provider: "aws", display_name: "aws-us-west-2", ui_name: "AWS US East 1", visible: true, project_id: project.id)
  }
  let(:location_credential) {
    LocationCredential.create_with_id(location, access_key: "test-access-key", secret_key: "test-secret-key")
  }
  let(:private_subnet) {
    Prog::Vnet::SubnetNexus.assemble(project.id, name: "test-ps", location_id: location.id).subject
  }
  let(:private_subnet_aws_resource) {
    PrivateSubnetAwsResource.create_with_id(private_subnet, security_group_id: "sg-1234567890")
  }
  let(:firewall) { private_subnet.firewalls.first }
  let(:vm) {
    location_credential
    private_subnet_aws_resource
    Prog::Vm::Nexus.assemble_with_sshable(project.id, location_id: location.id, private_subnet_id: private_subnet.id, name: "test-vm").subject
  }
  let(:st) { vm.strand }
  let(:ec2_client) { Aws::EC2::Client.new(stub_responses: true) }

  before do
    vm
    allow(Aws::EC2::Client).to receive(:new).with(credentials: anything, region: "us-west-2").and_return(ec2_client)
  end

  def create_firewall_rules
    # Clear default rules created by SubnetNexus.assemble
    firewall.firewall_rules.each(&:destroy)
    FirewallRule.create(firewall_id: firewall.id, cidr: "0.0.0.0/0", port_range: Sequel.pg_range(80..10000), protocol: "tcp")
    FirewallRule.create(firewall_id: firewall.id, cidr: "1.1.1.1/32", port_range: Sequel.pg_range(22..23), protocol: "tcp")
    FirewallRule.create(firewall_id: firewall.id, cidr: "fd00::1/128", port_range: Sequel.pg_range(80..10000), protocol: "tcp")
  end

  describe "#before_run" do
    it "pops if vm is to be destroyed" do
      vm.incr_destroy
      expect { nx.before_run }.to exit({"msg" => "firewall rule is added"})
    end

    it "does not pop if vm is not to be destroyed" do
      expect { nx.before_run }.not_to exit
    end
  end

  describe "update_firewall_rules" do
    it "hops to remove_aws_old_rules if there are no fw rules to add" do
      expect { nx.update_firewall_rules }.to hop("remove_aws_old_rules")
    end

    it "hops to remove_aws_old_rules after adding new rules" do
      create_firewall_rules
      expect(ec2_client).to receive(:authorize_security_group_ingress).with({
        group_id: "sg-1234567890",
        ip_permissions: [
          {
            ip_protocol: "tcp",
            from_port: 80,
            to_port: 10000,
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
            to_port: 23,
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
            to_port: 10000,
            ipv_6_ranges: [{cidr_ipv_6: "fd00::1/128"}]
          }
        ]
      })

      expect { nx.update_firewall_rules }.to hop("remove_aws_old_rules")
    end

    it "continues and hops to remove_aws_old_rules if there is a duplicate rule" do
      create_firewall_rules
      expect(ec2_client).to receive(:authorize_security_group_ingress).with({
        group_id: "sg-1234567890",
        ip_permissions: [
          {
            ip_protocol: "tcp",
            from_port: 80,
            to_port: 10000,
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
            to_port: 23,
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
            to_port: 10000,
            ipv_6_ranges: [{cidr_ipv_6: "fd00::1/128"}]
          }
        ]
      })

      expect { nx.update_firewall_rules }.to hop("remove_aws_old_rules")
    end
  end

  describe "#remove_aws_old_rules" do
    it "removes old rules" do
      create_firewall_rules
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
          to_port: 10000,
          ip_ranges: [],
          ipv_6_ranges: [{cidr_ipv_6: "fd00::1/128"}]
        },
        {
          ip_protocol: "tcp",
          from_port: 80,
          to_port: 10000,
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
      create_firewall_rules
      ec2_client.stub_responses(:describe_security_groups, security_groups: [ip_permissions: [
        {
          ip_protocol: "tcp",
          from_port: 80,
          to_port: 10000,
          ip_ranges: [{cidr_ip: "0.0.0.0/0"}],
          ipv_6_ranges: [{cidr_ipv_6: "fd00::1/128"}]
        },
        {
          ip_protocol: "tcp",
          from_port: 80,
          to_port: 10000,
          ip_ranges: [{cidr_ip: "0.0.0.0/0"}],
          ipv_6_ranges: []
        }
      ]])
      expect(ec2_client).not_to receive(:revoke_security_group_ingress)
      expect(ec2_client).to receive(:describe_security_groups)
        .with({group_ids: ["sg-1234567890"]})
        .and_call_original

      expect { nx.remove_aws_old_rules }.to exit({"msg" => "firewall rule is added"})
    end
  end
end
