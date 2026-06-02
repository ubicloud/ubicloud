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
    instance_double(Vm, project: instance_double(Project, get_ff_ipv6_disabled: false), private_subnets: [ps], vm_host: vmh, inhost_name: "x", nics: [nic], ephemeral_net6:, load_balancer: nil, private_ipv4: NetAddr::IPv4Net.parse("10.0.0.0/32").network, location: location.id)
  }

  describe "#before_run" do
    it "pops if vm is to be destroyed" do
      expect(nx).to receive(:vm).and_return(vm).at_least(:once)
      expect(vm).to receive(:destroy_set?).and_return(true)
      expect { nx.before_run }.to exit({"msg" => "firewall rules synced"})
    end

    it "does not pop if vm is not to be destroyed" do
      expect(nx).to receive(:vm).and_return(vm).at_least(:once)
      expect(vm).to receive(:destroy_set?).and_return(false)
      expect { nx.before_run }.not_to exit
    end
  end

  describe "#update_firewall_rules" do
    let(:ec2_client) { Aws::EC2::Client.new(stub_responses: true) }

    before do
      lcred = instance_double(LocationCredentialAws, client: ec2_client)
      loc = instance_double(Location, provider: "aws", location_credential_aws: lcred)
      allow(nx).to receive(:vm).and_return(vm)
      allow(vm).to receive(:location).and_return(loc)
      allow(vm.private_subnets.first).to receive(:private_subnet_aws_resource).and_return(instance_double(PrivateSubnetAwsResource, security_group_id: "sg-1234567890"))
    end

    it "exits without authorize or revoke when desired and existing match" do
      expect(vm).to receive(:firewall_rules).and_return([
        instance_double(FirewallRule, cidr: NetAddr::IPv4Net.parse("0.0.0.0/0"), port_range: Sequel.pg_range(80..10000), protocol: "tcp"),
        instance_double(FirewallRule, cidr: NetAddr::IPv6Net.parse("fd00::1/128"), port_range: Sequel.pg_range(80..10000), protocol: "tcp"),
      ])
      ec2_client.stub_responses(:describe_security_groups, security_groups: [ip_permissions: [
        {ip_protocol: "tcp", from_port: 80, to_port: 9999, ip_ranges: [{cidr_ip: "0.0.0.0/0"}], ipv_6_ranges: [{cidr_ipv_6: "fd00::1/128"}]},
      ]])
      expect(ec2_client).not_to receive(:authorize_security_group_ingress)
      expect(ec2_client).not_to receive(:revoke_security_group_ingress)

      expect { nx.update_firewall_rules }.to exit({"msg" => "firewall rules synced"})
    end

    it "exits without any call when there are no desired or existing rules" do
      expect(vm).to receive(:firewall_rules).and_return([])
      ec2_client.stub_responses(:describe_security_groups, security_groups: [ip_permissions: []])
      expect(ec2_client).not_to receive(:authorize_security_group_ingress)
      expect(ec2_client).not_to receive(:revoke_security_group_ingress)

      expect { nx.update_firewall_rules }.to exit({"msg" => "firewall rules synced"})
    end

    it "authorizes only rules missing from the security group in a single call" do
      expect(vm).to receive(:firewall_rules).and_return([
        instance_double(FirewallRule, cidr: NetAddr::IPv4Net.parse("0.0.0.0/0"), port_range: Sequel.pg_range(80..10000), protocol: "tcp"),
        instance_double(FirewallRule, cidr: NetAddr::IPv4Net.parse("1.1.1.1/32"), port_range: Sequel.pg_range(22..23), protocol: "tcp"),
        instance_double(FirewallRule, cidr: NetAddr::IPv6Net.parse("fd00::1/128"), port_range: Sequel.pg_range(80..10000), protocol: "tcp"),
      ])
      ec2_client.stub_responses(:describe_security_groups, security_groups: [ip_permissions: [
        {ip_protocol: "tcp", from_port: 80, to_port: 9999, ip_ranges: [{cidr_ip: "0.0.0.0/0"}], ipv_6_ranges: []},
      ]])
      expect(ec2_client).to receive(:authorize_security_group_ingress).with({
        group_id: "sg-1234567890",
        ip_permissions: [
          {ip_protocol: "tcp", from_port: 22, to_port: 22, ip_ranges: [{cidr_ip: "1.1.1.1/32"}]},
          {ip_protocol: "tcp", from_port: 80, to_port: 9999, ipv_6_ranges: [{cidr_ipv_6: "fd00::1/128"}]},
        ],
      })
      expect(ec2_client).not_to receive(:revoke_security_group_ingress)

      expect { nx.update_firewall_rules }.to exit({"msg" => "firewall rules synced"})
    end

    it "revokes only rules absent from the desired set in a single call" do
      expect(vm).to receive(:firewall_rules).and_return([])
      ec2_client.stub_responses(:describe_security_groups, security_groups: [ip_permissions: [
        {ip_protocol: "tcp", from_port: 22, to_port: 22, ip_ranges: [{cidr_ip: "1.1.1.1/32"}], ipv_6_ranges: []},
        {ip_protocol: "tcp", from_port: 80, to_port: 9999, ip_ranges: [{cidr_ip: "0.0.0.0/0"}], ipv_6_ranges: [{cidr_ipv_6: "fd00::1/128"}]},
      ]])
      expect(ec2_client).not_to receive(:authorize_security_group_ingress)
      expect(ec2_client).to receive(:revoke_security_group_ingress).with({
        group_id: "sg-1234567890",
        ip_permissions: [
          {ip_protocol: "tcp", from_port: 22, to_port: 22, ip_ranges: [{cidr_ip: "1.1.1.1/32"}]},
          {ip_protocol: "tcp", from_port: 80, to_port: 9999, ip_ranges: [{cidr_ip: "0.0.0.0/0"}], ipv_6_ranges: [{cidr_ipv_6: "fd00::1/128"}]},
        ],
      })

      expect { nx.update_firewall_rules }.to exit({"msg" => "firewall rules synced"})
    end

    it "authorizes additions and revokes removals in one pass" do
      expect(vm).to receive(:firewall_rules).and_return([
        instance_double(FirewallRule, cidr: NetAddr::IPv4Net.parse("0.0.0.0/0"), port_range: Sequel.pg_range(80..10000), protocol: "tcp"),
        instance_double(FirewallRule, cidr: NetAddr::IPv4Net.parse("1.1.1.1/32"), port_range: Sequel.pg_range(22..23), protocol: "tcp"),
        instance_double(FirewallRule, cidr: NetAddr::IPv6Net.parse("fd00::1/128"), port_range: Sequel.pg_range(80..10000), protocol: "tcp"),
      ])
      ec2_client.stub_responses(:describe_security_groups, security_groups: [ip_permissions: [
        {ip_protocol: "tcp", from_port: 0, to_port: 100, ip_ranges: [], ipv_6_ranges: [{cidr_ipv_6: "fd00::1/128"}]},
        {ip_protocol: "udp", from_port: 0, to_port: 100, ip_ranges: [{cidr_ip: "0.0.0.0/0"}], ipv_6_ranges: [{cidr_ipv_6: "fd00::1/128"}]},
        {ip_protocol: "tcp", from_port: 0, to_port: 100, ip_ranges: [{cidr_ip: "10.10.10.10/32"}], ipv_6_ranges: []},
        {ip_protocol: "tcp", from_port: 80, to_port: 9999, ip_ranges: [], ipv_6_ranges: [{cidr_ipv_6: "fd00::1/128"}]},
        {ip_protocol: "tcp", from_port: 80, to_port: 9999, ip_ranges: [{cidr_ip: "0.0.0.0/0"}], ipv_6_ranges: []},
      ]])
      expect(ec2_client).to receive(:authorize_security_group_ingress).with({
        group_id: "sg-1234567890",
        ip_permissions: [
          {ip_protocol: "tcp", from_port: 22, to_port: 22, ip_ranges: [{cidr_ip: "1.1.1.1/32"}]},
        ],
      })
      expect(ec2_client).to receive(:revoke_security_group_ingress).with({
        group_id: "sg-1234567890",
        ip_permissions: [
          {ip_protocol: "tcp", from_port: 0, to_port: 100, ip_ranges: [{cidr_ip: "10.10.10.10/32"}], ipv_6_ranges: [{cidr_ipv_6: "fd00::1/128"}]},
          {ip_protocol: "udp", from_port: 0, to_port: 100, ip_ranges: [{cidr_ip: "0.0.0.0/0"}], ipv_6_ranges: [{cidr_ipv_6: "fd00::1/128"}]},
        ],
      })

      expect { nx.update_firewall_rules }.to exit({"msg" => "firewall rules synced"})
    end

    it "naps for re-describe when authorize fails with InvalidPermissionDuplicate" do
      expect(vm).to receive(:firewall_rules).and_return([
        instance_double(FirewallRule, cidr: NetAddr::IPv4Net.parse("0.0.0.0/0"), port_range: Sequel.pg_range(80..10000), protocol: "tcp"),
      ])
      ec2_client.stub_responses(:describe_security_groups, security_groups: [ip_permissions: []])
      expect(ec2_client).to receive(:authorize_security_group_ingress).and_raise(Aws::EC2::Errors::InvalidPermissionDuplicate.new("Duplicate", "Duplicate"))
      expect(ec2_client).not_to receive(:revoke_security_group_ingress)

      expect { nx.update_firewall_rules }.to nap(0)
    end

    it "naps for re-describe when revoke fails with InvalidPermissionNotFound" do
      expect(vm).to receive(:firewall_rules).and_return([])
      ec2_client.stub_responses(:describe_security_groups, security_groups: [ip_permissions: [
        {ip_protocol: "tcp", from_port: 22, to_port: 22, ip_ranges: [{cidr_ip: "1.1.1.1/32"}], ipv_6_ranges: []},
      ]])
      expect(ec2_client).to receive(:revoke_security_group_ingress).and_raise(Aws::EC2::Errors::InvalidPermissionNotFound.new("NotFound", "NotFound"))

      expect { nx.update_firewall_rules }.to nap(0)
    end

    it "pages and naps without revoking when authorize hits the SG rule limit" do
      allow(vm).to receive(:ubid).and_return("vmubid")
      expect(vm).to receive(:firewall_rules).and_return([
        instance_double(FirewallRule, cidr: NetAddr::IPv4Net.parse("1.1.1.1/32"), port_range: Sequel.pg_range(22..23), protocol: "tcp"),
      ])
      ec2_client.stub_responses(:describe_security_groups, security_groups: [ip_permissions: [
        {ip_protocol: "tcp", from_port: 80, to_port: 9999, ip_ranges: [{cidr_ip: "0.0.0.0/0"}], ipv_6_ranges: []},
      ]])
      expect(ec2_client).to receive(:authorize_security_group_ingress).and_raise(Aws::EC2::Errors::RulesPerSecurityGroupLimitExceeded.new("LimitExceeded", "rule limit reached"))
      expect(ec2_client).not_to receive(:revoke_security_group_ingress)
      expect(Prog::PageNexus).to receive(:assemble).with(
        /AWS security group sg-1234567890 rule limit exceeded/,
        ["AwsSgRuleLimitExceeded", "sg-1234567890"],
        "vmubid",
        hash_including(extra_data: hash_including(aws_error: "rule limit reached")),
      )

      expect { nx.update_firewall_rules }.to nap(10 * 60)
    end

    it "converges in three passes when sibling strands race authorize and revoke" do
      rules = [
        instance_double(FirewallRule, cidr: NetAddr::IPv4Net.parse("10.0.0.1/32"), port_range: Sequel.pg_range(22..23), protocol: "tcp"),
        instance_double(FirewallRule, cidr: NetAddr::IPv4Net.parse("10.0.0.2/32"), port_range: Sequel.pg_range(22..23), protocol: "tcp"),
        instance_double(FirewallRule, cidr: NetAddr::IPv4Net.parse("10.0.0.3/32"), port_range: Sequel.pg_range(22..23), protocol: "tcp"),
        instance_double(FirewallRule, cidr: NetAddr::IPv4Net.parse("10.0.0.4/32"), port_range: Sequel.pg_range(22..23), protocol: "tcp"),
      ]
      allow(vm).to receive(:firewall_rules).and_return(rules)

      stale_a = {ip_protocol: "tcp", from_port: 0, to_port: 9, ip_ranges: [{cidr_ip: "192.168.1.0/24"}], ipv_6_ranges: []}
      stale_b = {ip_protocol: "tcp", from_port: 0, to_port: 9, ip_ranges: [{cidr_ip: "192.168.2.0/24"}], ipv_6_ranges: []}
      stale_c = {ip_protocol: "tcp", from_port: 0, to_port: 9, ip_ranges: [{cidr_ip: "192.168.3.0/24"}], ipv_6_ranges: []}
      sibling_added = {ip_protocol: "tcp", from_port: 22, to_port: 22, ip_ranges: [{cidr_ip: "10.0.0.1/32"}], ipv_6_ranges: []}
      all_desired = {ip_protocol: "tcp", from_port: 22, to_port: 22, ip_ranges: [{cidr_ip: "10.0.0.1/32"}, {cidr_ip: "10.0.0.2/32"}, {cidr_ip: "10.0.0.3/32"}, {cidr_ip: "10.0.0.4/32"}], ipv_6_ranges: []}

      ec2_client.stub_responses(:describe_security_groups,
        # Pass 1: 3 stale rules; nothing of ours added yet.
        {security_groups: [ip_permissions: [stale_a, stale_b, stale_c]]},
        # Pass 2: a sibling raced ahead and added 10.0.0.1, so our pass 1 authorize raised Duplicate.
        {security_groups: [ip_permissions: [sibling_added, stale_a, stale_b, stale_c]]},
        # Pass 3: our pass 2 authorize added the rest; a sibling revoked 192.168.1.0/24 between our describe and revoke.
        {security_groups: [ip_permissions: [all_desired, stale_b, stale_c]]})

      expect(ec2_client).to receive(:authorize_security_group_ingress).twice.and_invoke(
        ->(*) { raise Aws::EC2::Errors::InvalidPermissionDuplicate.new("Duplicate", "Duplicate") },
        ->(*) {},
      )
      expect(ec2_client).to receive(:revoke_security_group_ingress).twice.and_invoke(
        ->(*) { raise Aws::EC2::Errors::InvalidPermissionNotFound.new("NotFound", "NotFound") },
        ->(*) {},
      )

      expect { nx.update_firewall_rules }.to nap(0)
      expect { nx.update_firewall_rules }.to nap(0)
      expect { nx.update_firewall_rules }.to exit({"msg" => "firewall rules synced"})
    end

    it "resolves a prior rule-limit page on a successful sync" do
      page = Page.create(tag: Page.generate_tag(["AwsSgRuleLimitExceeded", "sg-1234567890"]), summary: "old")
      Strand.create_with_id(page, prog: "PageNexus", label: "wait")
      expect(vm).to receive(:firewall_rules).and_return([])
      ec2_client.stub_responses(:describe_security_groups, security_groups: [ip_permissions: []])

      expect { nx.update_firewall_rules }.to exit({"msg" => "firewall rules synced"})
      expect(page.resolve_set?).to be true
    end
  end

  describe "#remove_aws_old_rules" do
    it "hops back to update_firewall_rules so parked strands resync" do
      expect { nx.remove_aws_old_rules }.to hop("update_firewall_rules")
    end
  end
end
