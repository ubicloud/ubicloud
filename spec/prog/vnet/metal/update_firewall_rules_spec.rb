# frozen_string_literal: true

RSpec.describe Prog::Vnet::Metal::UpdateFirewallRules do
  subject(:nx) {
    described_class.new(st)
  }

  let(:project) { Project.create(name: "test-project") }
  let(:location_id) { Location::HETZNER_FSN1_ID }
  let(:vmh) { create_vm_host }
  let(:ps) {
    PrivateSubnet.create(
      name: "ps", location_id:,
      net6: "fd10:9b0b:6b4b:8fbb::/64",
      net4: "10.0.0.0/26",
      state: "waiting",
      project_id: project.id
    )
  }
  let(:firewall) {
    Firewall.create(name: "test-fw", location_id:, project_id: project.id).tap do |fw|
      fw.add_private_subnet(ps)
    end
  }
  let(:nic) {
    Nic.create(
      private_subnet_id: ps.id,
      private_ipv6: NetAddr::IPv6Net.parse("fd00::1/128"),
      private_ipv4: NetAddr::IPv4Net.parse("10.0.0.1/32"),
      mac: "00:00:00:00:00:01",
      name: "nic0",
      state: "active"
    )
  }
  let(:vm) {
    firewall
    Vm.create(
      vm_host_id: vmh.id,
      name: "test-vm",
      family: "standard",
      cores: 1,
      vcpus: 2,
      cpu_percent_limit: 200,
      cpu_burst_percent_limit: 0,
      memory_gib: 4,
      arch: "x64",
      boot_image: "ubuntu-jammy",
      location_id:,
      project_id: project.id,
      display_state: "running",
      ip4_enabled: false,
      unix_user: "ubi",
      public_key: "ssh-ed25519 test",
      ephemeral_net6: NetAddr::IPv6Net.parse("fd00::1/79"),
      created_at: Time.now
    ).tap do |v|
      nic.update(vm_id: v.id)
    end
  }
  let!(:st) {
    Strand.create_with_id(vm, prog: "Vnet::Metal::UpdateFirewallRules", label: "update_firewall_rules")
  }

  def sshable
    @sshable ||= nx.vm.vm_host.sshable
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
    def create_firewall_rules
      firewall.firewall_rules.each(&:destroy)
      [
        {cidr: "0.0.0.0/0", port_range: nil},
        {cidr: "1.1.1.1/32", port_range: Sequel.pg_range(22..23)},
        {cidr: "10.10.10.0/26", port_range: Sequel.pg_range(80..10000)},
        {cidr: "123.123.123.64/27", port_range: Sequel.pg_range(8080..12000)},
        {cidr: "123.123.123.64/26", port_range: Sequel.pg_range(9000..16000)},
        {cidr: "::/0", port_range: nil},
        {cidr: "fd00::1/128", port_range: Sequel.pg_range(8080..65535)},
        {cidr: "fd00::1/64", port_range: Sequel.pg_range(0..8081)},
        {cidr: "fd00::2/64", port_range: Sequel.pg_range(80..10000)}
      ].each do |rule|
        FirewallRule.create(firewall_id: firewall.id, cidr: rule[:cidr], port_range: rule[:port_range])
      end
    end

    it "populates elements if there are fw rules" do
      GloballyBlockedDnsname.create(dns_name: "blockedhost.com", ip_list: ["123.123.123.123", "2a00:1450:400e:811::200e"])
      create_firewall_rules
      expect(sshable).to receive(:_cmd) do |cmd, stdin:|
        expect(cmd).to match(/sudo ip netns exec #{vm.inhost_name} nft --file -/)
        expect(stdin).to include("table inet fw_table")
        expect(stdin).to include("set allowed_ipv4_port_tuple")
        expect(stdin).to include("1.1.1.1/32 . 22")
        expect(stdin).to include("10.10.10.0/26 . 80-")
        expect(stdin).to include("123.123.123.64")
        expect(stdin).to include("set allowed_ipv6_port_tuple")
        expect(stdin).to include("fd00::")
        expect(stdin).to include("set private_ipv4_cidrs")
        expect(stdin).to include("10.0.0.1/32")
        expect(stdin).to include("set private_ipv6_cidrs")
        expect(stdin).to include("fd00::1/128")
        expect(stdin).to include("set globally_blocked_ipv4s")
        expect(stdin).to include("123.123.123.123/32")
        expect(stdin).to include("set globally_blocked_ipv6s")
        expect(stdin).to include("2a00:1450:400e:811::200e/128")
        expect(stdin).to include("chain forward_ingress")
        expect(stdin).to include("# An nftables idiom for idempotent re-create")
        expect(stdin).to include("# Destination port 111 is reserved for the portmapper")
        expect(stdin).to include("# Drop all traffic from globally blocked IPs")
        expect(stdin).to include("# If we are using @private_ipv4_cidrs as source address")
        expect(stdin).to include("# If we are using clover_ephemeral, that means we are using ipsec")
        expect(stdin).to include("# Allow TCP and UDP traffic for allowed_ipv4_port_tuple")
        expect(stdin).to include("# Allow outgoing traffic from the VM")
        expect(stdin).to include("# Allow incoming traffic to the VM")
        expect(stdin).to include("# Allow ping for all")
        expect(stdin).to include("# Allow load balancer traffic")
      end

      expect { nx.update_firewall_rules }.to exit({"msg" => "firewall rule is added"})
    end

    it "populates load balancer destination sets and adds related rules" do
      GloballyBlockedDnsname.create(dns_name: "blockedhost.com", ip_list: ["123.123.123.123", "2a00:1450:400e:811::200e"])
      create_firewall_rules

      # Create load balancer with two VMs
      lb = LoadBalancer.create(
        name: "test-lb",
        health_check_protocol: "http",
        health_check_endpoint: "/health",
        project_id: project.id,
        private_subnet_id: ps.id
      )
      LoadBalancerPort.create(load_balancer_id: lb.id, src_port: 443, dst_port: 8443)

      # Create second VM with specific IPs
      nic2 = Nic.create(
        private_subnet_id: ps.id,
        private_ipv6: NetAddr::IPv6Net.parse("fd00::/124"),
        private_ipv4: NetAddr::IPv4Net.parse("10.0.0.2/32"),
        mac: "00:00:00:00:00:02",
        name: "nic2",
        state: "active"
      )
      vm2 = Vm.create(
        vm_host_id: vmh.id,
        name: "test-vm2",
        family: "standard",
        cores: 1,
        vcpus: 2,
        cpu_percent_limit: 200,
        cpu_burst_percent_limit: 0,
        memory_gib: 4,
        arch: "x64",
        boot_image: "ubuntu-jammy",
        location_id:,
        project_id: project.id,
        display_state: "running",
        ip4_enabled: false,
        unix_user: "ubi",
        public_key: "ssh-ed25519 test",
        ephemeral_net6: NetAddr::IPv6Net.parse("fd01::/79"),
        created_at: Time.now
      )
      nic2.update(vm_id: vm2.id)

      LoadBalancerVm.create(load_balancer_id: lb.id, vm_id: vm.id)
      LoadBalancerVm.create(load_balancer_id: lb.id, vm_id: vm2.id)
      expect(sshable).to receive(:_cmd) do |cmd, stdin:|
        expect(cmd).to match(/sudo ip netns exec #{vm.inhost_name} nft --file -/)
        expect(stdin).to include("table inet fw_table")
        expect(stdin).to include("set allowed_ipv4_lb_dest_set")
        expect(stdin).to include(". 8443")
        expect(stdin).to include("set allowed_ipv6_lb_dest_set")
        expect(stdin).to include("# Allow load balancer traffic")
        expect(stdin).to include("10.0.0.2 . 443")
        expect(stdin).to include("fd00::2 . 443")
        expect(stdin).to include("meta mark 0x00B1C100D")
        expect(stdin).to include("# The traffic that is routed to the local VM from the load balancer")
      end

      expect { nx.update_firewall_rules }.to exit({"msg" => "firewall rule is added"})
    end

    it "populates load balancer destination sets and adds related rules when there is a single load balancer vm" do
      GloballyBlockedDnsname.create(dns_name: "blockedhost.com", ip_list: ["123.123.123.123", "2a00:1450:400e:811::200e"])
      create_firewall_rules

      lb = LoadBalancer.create(
        name: "test-lb",
        health_check_protocol: "http",
        health_check_endpoint: "/health",
        project_id: project.id,
        private_subnet_id: ps.id
      )
      LoadBalancerPort.create(load_balancer_id: lb.id, src_port: 443, dst_port: 8443)
      LoadBalancerVm.create(load_balancer_id: lb.id, vm_id: vm.id)
      expect(sshable).to receive(:_cmd) do |cmd, stdin:|
        expect(cmd).to match(/sudo ip netns exec #{vm.inhost_name} nft --file -/)
        expect(stdin).to include("table inet fw_table")
        expect(stdin).to include("set allowed_ipv4_lb_dest_set")
        expect(stdin).to include(". 8443")
        expect(stdin).to include("meta mark 0x00B1C100D")
        expect(stdin).not_to match(/ip saddr \. tcp sport \{.*\. 443/)  # Single VM LB has no neighbor rules
        expect(stdin).to include("# The traffic that is routed to the local VM from the load balancer")
      end

      expect { nx.update_firewall_rules }.to exit({"msg" => "firewall rule is added"})
    end

    it "does not pass elements if there are not fw rules and ipv6 is disabled" do
      # An address to block but not discovered the ip_list, yet.
      GloballyBlockedDnsname.create(dns_name: "blockedhost.com", ip_list: nil)
      GloballyBlockedDnsname.create(dns_name: "blockedhost6.com", ip_list: ["2a00:1450:400e:811::200e"])

      project.set_ff_ipv6_disabled(true)
      expect(sshable).to receive(:_cmd) do |cmd, stdin:|
        expect(cmd).to match(/sudo ip netns exec #{vm.inhost_name} nft --file -/)
        expect(stdin).to include("table inet fw_table")
        expect(stdin).to include("set allowed_ipv4_port_tuple")
        # The allowed sets should have no elements (empty) since there are no firewall rules
        expect(stdin).to match(/set allowed_ipv4_port_tuple \{[^}]*\n\s*\}/)
        expect(stdin).to match(/set allowed_ipv6_port_tuple \{[^}]*\n\s*\}/)
        # When ipv6_disabled, these accept-all rules should be present
        expect(stdin).to include("ip6 daddr ::/0 counter accept")
        expect(stdin).to include("ip6 saddr ::/0 counter accept")
      end

      expect { nx.update_firewall_rules }.to exit({"msg" => "firewall rule is added"})
    end

    it "formats single-port firewall rules without range syntax" do
      GloballyBlockedDnsname.create(dns_name: "blockedhost.com", ip_list: ["123.123.123.123"])
      # Create only a single-port rule (port 443 only, not a range)
      firewall.firewall_rules.each(&:destroy)
      FirewallRule.create(firewall_id: firewall.id, cidr: "192.168.1.0/24", port_range: Sequel.pg_range(443..443))
      expect(sshable).to receive(:_cmd) do |cmd, stdin:|
        expect(cmd).to match(/sudo ip netns exec #{vm.inhost_name} nft --file -/)
        # Single port should be formatted as "cidr . port" without range syntax
        expect(stdin).to include("192.168.1.0/24 . 443")
        expect(stdin).not_to include("192.168.1.0/24 . 443-")
      end

      expect { nx.update_firewall_rules }.to exit({"msg" => "firewall rule is added"})
    end
  end
end
