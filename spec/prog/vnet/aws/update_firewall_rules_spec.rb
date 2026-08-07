# frozen_string_literal: true

RSpec.describe Prog::Vnet::Aws::UpdateFirewallRules do
  subject(:nx) { described_class.new(st) }

  let(:project) { Project.create(name: "aws-firewall-project") }
  let(:location) {
    Location.create(name: "us-west-2", provider: "aws", project_id: project.id,
      display_name: "aws-us-west-2", ui_name: "AWS US West 2", visible: true)
  }
  let(:credential) {
    LocationCredentialAws.create_with_id(location.id, access_key: "test-access-key", secret_key: "test-secret-key").tap do
      LocationAz.create(location_id: location.id, az: "a", zone_id: "usw2-az1")
    end
  }
  let(:vm) {
    credential
    Prog::Vm::Nexus.assemble_with_sshable(
      project.id,
      location_id: location.id,
      unix_user: "test-user",
      boot_image: "ami-test",
      name: "firewall-vm",
      size: "m6gd.large",
      arch: "arm64",
    ).subject.tap do |real_vm|
      real_vm.user_nic.private_subnet.private_subnet_aws_resource.update(user_security_group_id: "sg-shared")
      NicAwsResource.create_with_id(real_vm.user_nic.id, security_group_id: "sg-per-nic")
    end
  }
  let(:st) {
    vm.strand.update(prog: "Vnet::Aws::UpdateFirewallRules", label: "update_firewall_rules")
  }
  let(:ec2_client) { Aws::EC2::Client.new(stub_responses: true) }
  let(:firewall) { vm.user_nic.private_subnet.firewalls.first }
  let(:group_id) { "sg-per-nic" }

  before do
    firewall.firewall_rules_dataset.destroy
    allow(Aws::EC2::Client).to receive(:new).with(credentials: anything, region: "us-west-2").and_return(ec2_client)
  end

  def add_rule(cidr, from_port, to_port, protocol: "tcp")
    FirewallRule.create(
      firewall_id: firewall.id,
      cidr:,
      port_range: Sequel.pg_range(from_port...(to_port + 1)),
      protocol:,
    )
  end

  describe "#before_run" do
    it "pops if the vm is being destroyed" do
      vm.incr_destroy
      expect { nx.before_run }.to exit({"msg" => "firewall rules synced"})
    end

    it "continues if the vm is not being destroyed" do
      expect { nx.before_run }.not_to exit
    end
  end

  describe "#update_firewall_rules" do
    it "uses the per-NIC security group recorded for the runner" do
      ec2_client.stub_responses(:describe_security_groups, security_groups: [{group_id:, ip_permissions: []}])
      expect(ec2_client).to receive(:describe_security_groups).with({group_ids: ["sg-per-nic"]}).and_call_original

      expect { nx.update_firewall_rules }.to exit({"msg" => "firewall rules synced"})
    end

    it "falls back to the subnet group for a legacy nic without a dedicated group" do
      vm.user_nic.nic_aws_resource.update(security_group_id: nil)
      ec2_client.stub_responses(:describe_security_groups, security_groups: [{group_id: "sg-shared", ip_permissions: []}])
      expect(ec2_client).to receive(:describe_security_groups).with({group_ids: ["sg-shared"]}).and_call_original

      expect { nx.update_firewall_rules }.to exit({"msg" => "firewall rules synced"})
    end

    it "exits without authorize or revoke when desired and existing rules match" do
      add_rule("0.0.0.0/0", 80, 9999)
      add_rule("fd00::1/128", 80, 9999)
      ec2_client.stub_responses(:describe_security_groups, security_groups: [ip_permissions: [
        {ip_protocol: "tcp", from_port: 80, to_port: 9999, ip_ranges: [{cidr_ip: "0.0.0.0/0"}], ipv_6_ranges: [{cidr_ipv_6: "fd00::1/128"}]},
      ]])
      expect(ec2_client).not_to receive(:authorize_security_group_ingress)
      expect(ec2_client).not_to receive(:revoke_security_group_ingress)

      expect { nx.update_firewall_rules }.to exit({"msg" => "firewall rules synced"})
    end

    it "exits without mutation when there are no desired or existing rules" do
      ec2_client.stub_responses(:describe_security_groups, security_groups: [ip_permissions: []])
      expect(ec2_client).not_to receive(:authorize_security_group_ingress)
      expect(ec2_client).not_to receive(:revoke_security_group_ingress)

      expect { nx.update_firewall_rules }.to exit({"msg" => "firewall rules synced"})
    end

    it "authorizes only rules missing from the security group in one call" do
      add_rule("0.0.0.0/0", 80, 9999)
      add_rule("1.1.1.1/32", 22, 22)
      add_rule("fd00::1/128", 80, 9999)
      ec2_client.stub_responses(:describe_security_groups, security_groups: [ip_permissions: [
        {ip_protocol: "tcp", from_port: 80, to_port: 9999, ip_ranges: [{cidr_ip: "0.0.0.0/0"}], ipv_6_ranges: []},
      ]])
      ec2_client.stub_responses(:authorize_security_group_ingress)
      expect(ec2_client).to receive(:authorize_security_group_ingress).with({
        group_id:,
        ip_permissions: [
          {ip_protocol: "tcp", from_port: 22, to_port: 22, ip_ranges: [{cidr_ip: "1.1.1.1/32"}]},
          {ip_protocol: "tcp", from_port: 80, to_port: 9999, ipv_6_ranges: [{cidr_ipv_6: "fd00::1/128"}]},
        ],
      }).and_call_original
      expect(ec2_client).not_to receive(:revoke_security_group_ingress)

      expect { nx.update_firewall_rules }.to exit({"msg" => "firewall rules synced"})
    end

    it "revokes only rules absent from the desired set in one call" do
      ec2_client.stub_responses(:describe_security_groups, security_groups: [ip_permissions: [
        {ip_protocol: "tcp", from_port: 22, to_port: 22, ip_ranges: [{cidr_ip: "1.1.1.1/32"}], ipv_6_ranges: []},
        {ip_protocol: "tcp", from_port: 80, to_port: 9999, ip_ranges: [{cidr_ip: "0.0.0.0/0"}], ipv_6_ranges: [{cidr_ipv_6: "fd00::1/128"}]},
      ]])
      ec2_client.stub_responses(:revoke_security_group_ingress)
      expect(ec2_client).not_to receive(:authorize_security_group_ingress)
      expect(ec2_client).to receive(:revoke_security_group_ingress).with({
        group_id:,
        ip_permissions: [
          {ip_protocol: "tcp", from_port: 22, to_port: 22, ip_ranges: [{cidr_ip: "1.1.1.1/32"}]},
          {ip_protocol: "tcp", from_port: 80, to_port: 9999, ip_ranges: [{cidr_ip: "0.0.0.0/0"}], ipv_6_ranges: [{cidr_ipv_6: "fd00::1/128"}]},
        ],
      }).and_call_original

      expect { nx.update_firewall_rules }.to exit({"msg" => "firewall rules synced"})
    end

    it "authorizes additions and revokes removals in one pass" do
      add_rule("0.0.0.0/0", 80, 9999)
      add_rule("1.1.1.1/32", 22, 22)
      add_rule("fd00::1/128", 80, 9999)
      ec2_client.stub_responses(:describe_security_groups, security_groups: [ip_permissions: [
        {ip_protocol: "tcp", from_port: 0, to_port: 100, ip_ranges: [], ipv_6_ranges: [{cidr_ipv_6: "fd00::1/128"}]},
        {ip_protocol: "udp", from_port: 0, to_port: 100, ip_ranges: [{cidr_ip: "0.0.0.0/0"}], ipv_6_ranges: [{cidr_ipv_6: "fd00::1/128"}]},
        {ip_protocol: "tcp", from_port: 0, to_port: 100, ip_ranges: [{cidr_ip: "10.10.10.10/32"}], ipv_6_ranges: []},
        {ip_protocol: "tcp", from_port: 80, to_port: 9999, ip_ranges: [], ipv_6_ranges: [{cidr_ipv_6: "fd00::1/128"}]},
        {ip_protocol: "tcp", from_port: 80, to_port: 9999, ip_ranges: [{cidr_ip: "0.0.0.0/0"}], ipv_6_ranges: []},
      ]])
      ec2_client.stub_responses(:authorize_security_group_ingress)
      ec2_client.stub_responses(:revoke_security_group_ingress)
      expect(ec2_client).to receive(:authorize_security_group_ingress).with({
        group_id:,
        ip_permissions: [
          {ip_protocol: "tcp", from_port: 22, to_port: 22, ip_ranges: [{cidr_ip: "1.1.1.1/32"}]},
        ],
      }).and_call_original
      expect(ec2_client).to receive(:revoke_security_group_ingress).with({
        group_id:,
        ip_permissions: [
          {ip_protocol: "tcp", from_port: 0, to_port: 100, ip_ranges: [{cidr_ip: "10.10.10.10/32"}], ipv_6_ranges: [{cidr_ipv_6: "fd00::1/128"}]},
          {ip_protocol: "udp", from_port: 0, to_port: 100, ip_ranges: [{cidr_ip: "0.0.0.0/0"}], ipv_6_ranges: [{cidr_ipv_6: "fd00::1/128"}]},
        ],
      }).and_call_original

      expect { nx.update_firewall_rules }.to exit({"msg" => "firewall rules synced"})
    end

    it "naps for a fresh describe when authorize reports a duplicate" do
      add_rule("0.0.0.0/0", 80, 9999)
      ec2_client.stub_responses(:describe_security_groups, security_groups: [ip_permissions: []])
      ec2_client.stub_responses(:authorize_security_group_ingress, Aws::EC2::Errors::InvalidPermissionDuplicate.new("Duplicate", "Duplicate"))
      expect(ec2_client).not_to receive(:revoke_security_group_ingress)

      expect { nx.update_firewall_rules }.to nap(0)
    end

    it "naps for a fresh describe when revoke reports a missing permission" do
      ec2_client.stub_responses(:describe_security_groups, security_groups: [ip_permissions: [
        {ip_protocol: "tcp", from_port: 22, to_port: 22, ip_ranges: [{cidr_ip: "1.1.1.1/32"}], ipv_6_ranges: []},
      ]])
      ec2_client.stub_responses(:revoke_security_group_ingress, Aws::EC2::Errors::InvalidPermissionNotFound.new("NotFound", "NotFound"))

      expect { nx.update_firewall_rules }.to nap(0)
    end

    it "pages and naps without revoking when authorize reaches the group rule limit" do
      add_rule("1.1.1.1/32", 22, 22)
      ec2_client.stub_responses(:describe_security_groups, security_groups: [ip_permissions: [
        {ip_protocol: "tcp", from_port: 80, to_port: 9999, ip_ranges: [{cidr_ip: "0.0.0.0/0"}], ipv_6_ranges: []},
      ]])
      ec2_client.stub_responses(:authorize_security_group_ingress, Aws::EC2::Errors::RulesPerSecurityGroupLimitExceeded.new("LimitExceeded", "rule limit reached"))
      expect(ec2_client).not_to receive(:revoke_security_group_ingress)

      expect { nx.update_firewall_rules }.to nap(10 * 60).and change(Page, :count).by(1)
      page = Page.from_tag_parts("AwsSgRuleLimitExceeded", group_id)
      expect(page).not_to be_nil
      expect(page.summary).to include("AWS security group #{group_id} rule limit exceeded")
    end

    it "converges in three passes when sibling strands race authorize and revoke" do
      add_rule("10.0.0.1/32", 22, 22)
      add_rule("10.0.0.2/32", 22, 22)
      add_rule("10.0.0.3/32", 22, 22)
      add_rule("10.0.0.4/32", 22, 22)

      stale_a = {ip_protocol: "tcp", from_port: 0, to_port: 9, ip_ranges: [{cidr_ip: "192.168.1.0/24"}], ipv_6_ranges: []}
      stale_b = {ip_protocol: "tcp", from_port: 0, to_port: 9, ip_ranges: [{cidr_ip: "192.168.2.0/24"}], ipv_6_ranges: []}
      stale_c = {ip_protocol: "tcp", from_port: 0, to_port: 9, ip_ranges: [{cidr_ip: "192.168.3.0/24"}], ipv_6_ranges: []}
      sibling_added = {ip_protocol: "tcp", from_port: 22, to_port: 22, ip_ranges: [{cidr_ip: "10.0.0.1/32"}], ipv_6_ranges: []}
      all_desired = {ip_protocol: "tcp", from_port: 22, to_port: 22, ip_ranges: [{cidr_ip: "10.0.0.1/32"}, {cidr_ip: "10.0.0.2/32"}, {cidr_ip: "10.0.0.3/32"}, {cidr_ip: "10.0.0.4/32"}], ipv_6_ranges: []}

      ec2_client.stub_responses(:describe_security_groups,
        {security_groups: [ip_permissions: [stale_a, stale_b, stale_c]]},
        {security_groups: [ip_permissions: [sibling_added, stale_a, stale_b, stale_c]]},
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

    it "resolves a prior rule-limit page after a successful sync" do
      page = Page.create(tag: Page.generate_tag(["AwsSgRuleLimitExceeded", group_id]), summary: "old")
      Strand.create_with_id(page, prog: "PageNexus", label: "wait")
      ec2_client.stub_responses(:describe_security_groups, security_groups: [ip_permissions: []])

      expect { nx.update_firewall_rules }.to exit({"msg" => "firewall rules synced"})
      expect(page.reload.resolve_set?).to be true
    end
  end

  describe "#remove_aws_old_rules" do
    it "hops back to update_firewall_rules so parked strands resync" do
      expect { nx.remove_aws_old_rules }.to hop("update_firewall_rules")
    end
  end
end
