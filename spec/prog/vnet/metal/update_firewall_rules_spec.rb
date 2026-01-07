# frozen_string_literal: true

RSpec.describe Prog::Vnet::Metal::UpdateFirewallRules do
  subject(:nx) {
    described_class.new(@st)
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
      project:
    )
  }
  let(:firewall) {
    Firewall.create(name: "test-fw", location_id:, project:).tap do |fw|
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
      vm_host: vmh,
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
      ephemeral_net6: NetAddr::IPv6Net.parse("fd00::1/79")
    ).tap do |v|
      nic.update(vm_id: v.id)
    end
  }
  let(:sshable) { nx.vm.vm_host.sshable }

  before do
    @st = Strand.create_with_id(vm, prog: "Vnet::Metal::UpdateFirewallRules", label: "update_firewall_rules")
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
      firewall.replace_firewall_rules([
        {cidr: "0.0.0.0/0", port_range: nil},
        {cidr: "1.1.1.1/32", port_range: Sequel.pg_range(22..22)},
        {cidr: "10.10.10.0/26", port_range: Sequel.pg_range(80..9999)},
        {cidr: "123.123.123.64/27", port_range: Sequel.pg_range(8080..11999)},
        {cidr: "123.123.123.64/26", port_range: Sequel.pg_range(9000..15999)},
        {cidr: "::/0", port_range: nil},
        {cidr: "fd00::1/128", port_range: Sequel.pg_range(8080..65535)},
        {cidr: "fd00::1/64", port_range: Sequel.pg_range(0..8080)},
        {cidr: "fd00::2/64", port_range: Sequel.pg_range(80..9999)}
      ])
    end

    it "populates elements if there are fw rules" do
      GloballyBlockedDnsname.create(dns_name: "blockedhost.com", ip_list: ["123.123.123.123", "2a00:1450:400e:811::200e"])
      create_firewall_rules

      expect(sshable).to receive(:_cmd).with("sudo ip netns exec #{vm.inhost_name} nft --file -", stdin: <<ADD_RULES)
# An nftables idiom for idempotent re-create of a named entity: merge
# in an empty table (a no-op if the table already exists) and then
# delete, before creating with a new definition.
table inet fw_table;
delete table inet fw_table;
table inet fw_table {
  set allowed_ipv4_port_tuple {
    type ipv4_addr . inet_service;
    flags interval;
elements = {1.1.1.1/32 . 22,10.10.10.0/26 . 80-9999,123.123.123.64/26 . 9000-15999,123.123.123.64/27 . 8080-8999}
  }

  set allowed_ipv4_lb_dest_set {
    type ipv4_addr . inet_service;
    flags interval;

  }

  set allowed_ipv6_port_tuple {
    type ipv6_addr . inet_service;
    flags interval;
elements = {fd00::/64 . 0-9999,fd00::1/128 . 10000-65535}
  }

  set allowed_ipv6_lb_dest_set {
    type ipv6_addr . inet_service;
    flags interval;

  }

  set private_ipv4_cidrs {
    type ipv4_addr;
    flags interval;
    elements = {
      10.0.0.1/32
    }
  }

  set private_ipv6_cidrs {
    type ipv6_addr
    flags interval
    elements = { fd00::1/128 }
  }

  set globally_blocked_ipv4s {
    type ipv4_addr;
    flags interval;
elements = {123.123.123.123/32}
  }

  set globally_blocked_ipv6s {
    type ipv6_addr;
    flags interval;
elements = {2a00:1450:400e:811::200e/128}
  }

  chain forward_ingress {
    type filter hook forward priority filter; policy drop;

    # Destination port 111 is reserved for the portmapper. We block it to
    # prevent abuse.
    meta l4proto { tcp, udp } th dport 111 drop

    # Drop all traffic from globally blocked IPs. This is mainly used to
    # block access to malicious IPs that are known to cause issues on the
    # internet.
    ip saddr @globally_blocked_ipv4s drop
    ip6 saddr @globally_blocked_ipv6s drop
    ip daddr @globally_blocked_ipv4s drop
    ip6 daddr @globally_blocked_ipv6s drop

    # If we are using @private_ipv4_cidrs as source address, we allow all
    # established,related,new traffic because this is outgoing traffic.
    ip saddr @private_ipv4_cidrs ct state established,related,new counter accept

    # If we are using clover_ephemeral, that means we are using ipsec. We need
    # to allow traffic for the private communication and block via firewall
    # rules through @allowed_ipv4_port_tuple and @allowed_ipv6_port_tuple in the
    # next section of rules.
    ip6 daddr fd00::1:0:0:0/80 counter accept
    ip6 saddr fd00::1:0:0:0/80 counter accept

    # Allow TCP and UDP traffic for allowed_ipv4_port_tuple and
    # allowed_ipv6_port_tuple into the VM using any address, such as;
    #  - public ipv4
    #  - private ipv4
    #  - public ipv6 (guest_ephemeral)
    #  - private ipv6
    #  - private clover ephemeral ipv6
    ip saddr . tcp dport @allowed_ipv4_port_tuple ct state established,related,new counter accept
    ip saddr . udp dport @allowed_ipv4_port_tuple ct state established,related,new counter accept
    ip6 saddr . tcp dport @allowed_ipv6_port_tuple ct state established,related,new counter accept
    ip6 saddr . udp dport @allowed_ipv6_port_tuple ct state established,related,new counter accept

    # Allow outgoing traffic from the VM using the following addresses as
    # source address.
    ip6 saddr @private_ipv6_cidrs ct state established,related,new counter accept
    ip6 saddr fd00::/80 ct state established,related,new counter accept

    # Allow incoming traffic to the VM using the following addresses as
    # destination address. This is needed to allow the return traffic.
    ip6 daddr @private_ipv6_cidrs ct state established,related counter accept
    ip6 daddr fd00::/80 ct state established,related counter accept
    ip daddr @private_ipv4_cidrs ct state established,related counter accept

    # Allow ping for all
    ip saddr 0.0.0.0/0 icmp type echo-request counter accept
    ip daddr 0.0.0.0/0 icmp type echo-request counter accept
    ip saddr 0.0.0.0/0 icmp type echo-reply counter accept
    ip daddr 0.0.0.0/0 icmp type echo-reply counter accept
    ip6 saddr ::/0 icmpv6 type echo-request counter accept
    ip6 daddr ::/0 icmpv6 type echo-request counter accept
    ip6 saddr ::/0 icmpv6 type echo-reply counter accept
    ip6 daddr ::/0 icmpv6 type echo-reply counter accept

    # Allow load balancer traffic

  }
}
ADD_RULES

      expect { nx.update_firewall_rules }.to exit({"msg" => "firewall rule is added"})
    end

    it "populates load balancer destination sets and adds related rules" do
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

      nic2 = Nic.create(
        private_subnet_id: ps.id,
        private_ipv6: NetAddr::IPv6Net.parse("fd00::/124"),
        private_ipv4: NetAddr::IPv4Net.parse("10.0.0.2/32"),
        mac: "00:00:00:00:00:02",
        name: "nic2",
        state: "active"
      )
      vm2 = Vm.create(
        vm_host: vmh,
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
        ephemeral_net6: NetAddr::IPv6Net.parse("fd01::/79")
      )
      nic2.update(vm_id: vm2.id)

      LoadBalancerVm.create(load_balancer_id: lb.id, vm_id: vm.id)
      LoadBalancerVm.create(load_balancer_id: lb.id, vm_id: vm2.id)

      expect(sshable).to receive(:_cmd).with("sudo ip netns exec #{vm.inhost_name} nft --file -", stdin: <<ADD_RULES)
# An nftables idiom for idempotent re-create of a named entity: merge
# in an empty table (a no-op if the table already exists) and then
# delete, before creating with a new definition.
table inet fw_table;
delete table inet fw_table;
table inet fw_table {
  set allowed_ipv4_port_tuple {
    type ipv4_addr . inet_service;
    flags interval;
elements = {1.1.1.1/32 . 22,10.10.10.0/26 . 80-9999,123.123.123.64/26 . 9000-15999,123.123.123.64/27 . 8080-8999}
  }

  set allowed_ipv4_lb_dest_set {
    type ipv4_addr . inet_service;
    flags interval;
elements = {10.10.10.0/26 . 8443}
  }

  set allowed_ipv6_port_tuple {
    type ipv6_addr . inet_service;
    flags interval;
elements = {fd00::/64 . 0-9999,fd00::1/128 . 10000-65535}
  }

  set allowed_ipv6_lb_dest_set {
    type ipv6_addr . inet_service;
    flags interval;
elements = {fd00::/64 . 8443}
  }

  set private_ipv4_cidrs {
    type ipv4_addr;
    flags interval;
    elements = {
      10.0.0.1/32
    }
  }

  set private_ipv6_cidrs {
    type ipv6_addr
    flags interval
    elements = { fd00::1/128 }
  }

  set globally_blocked_ipv4s {
    type ipv4_addr;
    flags interval;
elements = {123.123.123.123/32}
  }

  set globally_blocked_ipv6s {
    type ipv6_addr;
    flags interval;
elements = {2a00:1450:400e:811::200e/128}
  }

  chain forward_ingress {
    type filter hook forward priority filter; policy drop;

    # Destination port 111 is reserved for the portmapper. We block it to
    # prevent abuse.
    meta l4proto { tcp, udp } th dport 111 drop

    # Drop all traffic from globally blocked IPs. This is mainly used to
    # block access to malicious IPs that are known to cause issues on the
    # internet.
    ip saddr @globally_blocked_ipv4s drop
    ip6 saddr @globally_blocked_ipv6s drop
    ip daddr @globally_blocked_ipv4s drop
    ip6 daddr @globally_blocked_ipv6s drop

    # If we are using @private_ipv4_cidrs as source address, we allow all
    # established,related,new traffic because this is outgoing traffic.
    ip saddr @private_ipv4_cidrs ct state established,related,new counter accept

    # If we are using clover_ephemeral, that means we are using ipsec. We need
    # to allow traffic for the private communication and block via firewall
    # rules through @allowed_ipv4_port_tuple and @allowed_ipv6_port_tuple in the
    # next section of rules.
    ip6 daddr fd00::1:0:0:0/80 counter accept
    ip6 saddr fd00::1:0:0:0/80 counter accept

    # Allow TCP and UDP traffic for allowed_ipv4_port_tuple and
    # allowed_ipv6_port_tuple into the VM using any address, such as;
    #  - public ipv4
    #  - private ipv4
    #  - public ipv6 (guest_ephemeral)
    #  - private ipv6
    #  - private clover ephemeral ipv6
    ip saddr . tcp dport @allowed_ipv4_port_tuple ct state established,related,new counter accept
    ip saddr . udp dport @allowed_ipv4_port_tuple ct state established,related,new counter accept
    ip6 saddr . tcp dport @allowed_ipv6_port_tuple ct state established,related,new counter accept
    ip6 saddr . udp dport @allowed_ipv6_port_tuple ct state established,related,new counter accept

    # Allow outgoing traffic from the VM using the following addresses as
    # source address.
    ip6 saddr @private_ipv6_cidrs ct state established,related,new counter accept
    ip6 saddr fd00::/80 ct state established,related,new counter accept

    # Allow incoming traffic to the VM using the following addresses as
    # destination address. This is needed to allow the return traffic.
    ip6 daddr @private_ipv6_cidrs ct state established,related counter accept
    ip6 daddr fd00::/80 ct state established,related counter accept
    ip daddr @private_ipv4_cidrs ct state established,related counter accept

    # Allow ping for all
    ip saddr 0.0.0.0/0 icmp type echo-request counter accept
    ip daddr 0.0.0.0/0 icmp type echo-request counter accept
    ip saddr 0.0.0.0/0 icmp type echo-reply counter accept
    ip daddr 0.0.0.0/0 icmp type echo-reply counter accept
    ip6 saddr ::/0 icmpv6 type echo-request counter accept
    ip6 daddr ::/0 icmpv6 type echo-request counter accept
    ip6 saddr ::/0 icmpv6 type echo-reply counter accept
    ip6 daddr ::/0 icmpv6 type echo-reply counter accept

    # Allow load balancer traffic
ip saddr . tcp sport { 10.0.0.2 . 443 } ct state established,related,new counter accept
ip6 saddr . tcp sport { fd00::2 . 443 } ct state established,related,new counter accept

# The traffic that is routed to the local VM from the load balancer
# is marked with 0x00B1C100D. We need to allow this traffic to
# the local VM.
meta mark 0x00B1C100D ip saddr . tcp dport @allowed_ipv4_lb_dest_set ct state established,related,new counter accept
meta mark 0x00B1C100D ip6 saddr . tcp dport @allowed_ipv6_lb_dest_set ct state established,related,new counter accept

  }
}
ADD_RULES

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

      expect(sshable).to receive(:_cmd).with("sudo ip netns exec #{vm.inhost_name} nft --file -", stdin: <<ADD_RULES)
# An nftables idiom for idempotent re-create of a named entity: merge
# in an empty table (a no-op if the table already exists) and then
# delete, before creating with a new definition.
table inet fw_table;
delete table inet fw_table;
table inet fw_table {
  set allowed_ipv4_port_tuple {
    type ipv4_addr . inet_service;
    flags interval;
elements = {1.1.1.1/32 . 22,10.10.10.0/26 . 80-9999,123.123.123.64/26 . 9000-15999,123.123.123.64/27 . 8080-8999}
  }

  set allowed_ipv4_lb_dest_set {
    type ipv4_addr . inet_service;
    flags interval;
elements = {10.10.10.0/26 . 8443}
  }

  set allowed_ipv6_port_tuple {
    type ipv6_addr . inet_service;
    flags interval;
elements = {fd00::/64 . 0-9999,fd00::1/128 . 10000-65535}
  }

  set allowed_ipv6_lb_dest_set {
    type ipv6_addr . inet_service;
    flags interval;
elements = {fd00::/64 . 8443}
  }

  set private_ipv4_cidrs {
    type ipv4_addr;
    flags interval;
    elements = {
      10.0.0.1/32
    }
  }

  set private_ipv6_cidrs {
    type ipv6_addr
    flags interval
    elements = { fd00::1/128 }
  }

  set globally_blocked_ipv4s {
    type ipv4_addr;
    flags interval;
elements = {123.123.123.123/32}
  }

  set globally_blocked_ipv6s {
    type ipv6_addr;
    flags interval;
elements = {2a00:1450:400e:811::200e/128}
  }

  chain forward_ingress {
    type filter hook forward priority filter; policy drop;

    # Destination port 111 is reserved for the portmapper. We block it to
    # prevent abuse.
    meta l4proto { tcp, udp } th dport 111 drop

    # Drop all traffic from globally blocked IPs. This is mainly used to
    # block access to malicious IPs that are known to cause issues on the
    # internet.
    ip saddr @globally_blocked_ipv4s drop
    ip6 saddr @globally_blocked_ipv6s drop
    ip daddr @globally_blocked_ipv4s drop
    ip6 daddr @globally_blocked_ipv6s drop

    # If we are using @private_ipv4_cidrs as source address, we allow all
    # established,related,new traffic because this is outgoing traffic.
    ip saddr @private_ipv4_cidrs ct state established,related,new counter accept

    # If we are using clover_ephemeral, that means we are using ipsec. We need
    # to allow traffic for the private communication and block via firewall
    # rules through @allowed_ipv4_port_tuple and @allowed_ipv6_port_tuple in the
    # next section of rules.
    ip6 daddr fd00::1:0:0:0/80 counter accept
    ip6 saddr fd00::1:0:0:0/80 counter accept

    # Allow TCP and UDP traffic for allowed_ipv4_port_tuple and
    # allowed_ipv6_port_tuple into the VM using any address, such as;
    #  - public ipv4
    #  - private ipv4
    #  - public ipv6 (guest_ephemeral)
    #  - private ipv6
    #  - private clover ephemeral ipv6
    ip saddr . tcp dport @allowed_ipv4_port_tuple ct state established,related,new counter accept
    ip saddr . udp dport @allowed_ipv4_port_tuple ct state established,related,new counter accept
    ip6 saddr . tcp dport @allowed_ipv6_port_tuple ct state established,related,new counter accept
    ip6 saddr . udp dport @allowed_ipv6_port_tuple ct state established,related,new counter accept

    # Allow outgoing traffic from the VM using the following addresses as
    # source address.
    ip6 saddr @private_ipv6_cidrs ct state established,related,new counter accept
    ip6 saddr fd00::/80 ct state established,related,new counter accept

    # Allow incoming traffic to the VM using the following addresses as
    # destination address. This is needed to allow the return traffic.
    ip6 daddr @private_ipv6_cidrs ct state established,related counter accept
    ip6 daddr fd00::/80 ct state established,related counter accept
    ip daddr @private_ipv4_cidrs ct state established,related counter accept

    # Allow ping for all
    ip saddr 0.0.0.0/0 icmp type echo-request counter accept
    ip daddr 0.0.0.0/0 icmp type echo-request counter accept
    ip saddr 0.0.0.0/0 icmp type echo-reply counter accept
    ip daddr 0.0.0.0/0 icmp type echo-reply counter accept
    ip6 saddr ::/0 icmpv6 type echo-request counter accept
    ip6 daddr ::/0 icmpv6 type echo-request counter accept
    ip6 saddr ::/0 icmpv6 type echo-reply counter accept
    ip6 daddr ::/0 icmpv6 type echo-reply counter accept

    # Allow load balancer traffic



# The traffic that is routed to the local VM from the load balancer
# is marked with 0x00B1C100D. We need to allow this traffic to
# the local VM.
meta mark 0x00B1C100D ip saddr . tcp dport @allowed_ipv4_lb_dest_set ct state established,related,new counter accept
meta mark 0x00B1C100D ip6 saddr . tcp dport @allowed_ipv6_lb_dest_set ct state established,related,new counter accept

  }
}
ADD_RULES

      expect { nx.update_firewall_rules }.to exit({"msg" => "firewall rule is added"})
    end

    it "does not pass elements if there are not fw rules and ipv6 is disabled" do
      # An address to block but not discovered the ip_list, yet.
      GloballyBlockedDnsname.create(dns_name: "blockedhost.com", ip_list: nil)
      GloballyBlockedDnsname.create(dns_name: "blockedhost6.com", ip_list: ["2a00:1450:400e:811::200e"])

      project.set_ff_ipv6_disabled(true)

      expect(sshable).to receive(:_cmd).with("sudo ip netns exec #{vm.inhost_name} nft --file -", stdin: <<ADD_RULES)
# An nftables idiom for idempotent re-create of a named entity: merge
# in an empty table (a no-op if the table already exists) and then
# delete, before creating with a new definition.
table inet fw_table;
delete table inet fw_table;
table inet fw_table {
  set allowed_ipv4_port_tuple {
    type ipv4_addr . inet_service;
    flags interval;

  }

  set allowed_ipv4_lb_dest_set {
    type ipv4_addr . inet_service;
    flags interval;

  }

  set allowed_ipv6_port_tuple {
    type ipv6_addr . inet_service;
    flags interval;

  }

  set allowed_ipv6_lb_dest_set {
    type ipv6_addr . inet_service;
    flags interval;

  }

  set private_ipv4_cidrs {
    type ipv4_addr;
    flags interval;
    elements = {
      10.0.0.1/32
    }
  }

  set private_ipv6_cidrs {
    type ipv6_addr
    flags interval
    elements = { fd00::1/128 }
  }

  set globally_blocked_ipv4s {
    type ipv4_addr;
    flags interval;

  }

  set globally_blocked_ipv6s {
    type ipv6_addr;
    flags interval;

  }

  chain forward_ingress {
    type filter hook forward priority filter; policy drop;

    # Destination port 111 is reserved for the portmapper. We block it to
    # prevent abuse.
    meta l4proto { tcp, udp } th dport 111 drop

    # Drop all traffic from globally blocked IPs. This is mainly used to
    # block access to malicious IPs that are known to cause issues on the
    # internet.
    ip saddr @globally_blocked_ipv4s drop
    ip6 saddr @globally_blocked_ipv6s drop
    ip daddr @globally_blocked_ipv4s drop
    ip6 daddr @globally_blocked_ipv6s drop

    # If we are using @private_ipv4_cidrs as source address, we allow all
    # established,related,new traffic because this is outgoing traffic.
    ip saddr @private_ipv4_cidrs ct state established,related,new counter accept

    # If we are using clover_ephemeral, that means we are using ipsec. We need
    # to allow traffic for the private communication and block via firewall
    # rules through @allowed_ipv4_port_tuple and @allowed_ipv6_port_tuple in the
    # next section of rules.
    ip6 daddr ::/0 counter accept
    ip6 saddr ::/0 counter accept

    # Allow TCP and UDP traffic for allowed_ipv4_port_tuple and
    # allowed_ipv6_port_tuple into the VM using any address, such as;
    #  - public ipv4
    #  - private ipv4
    #  - public ipv6 (guest_ephemeral)
    #  - private ipv6
    #  - private clover ephemeral ipv6
    ip saddr . tcp dport @allowed_ipv4_port_tuple ct state established,related,new counter accept
    ip saddr . udp dport @allowed_ipv4_port_tuple ct state established,related,new counter accept
    ip6 saddr . tcp dport @allowed_ipv6_port_tuple ct state established,related,new counter accept
    ip6 saddr . udp dport @allowed_ipv6_port_tuple ct state established,related,new counter accept

    # Allow outgoing traffic from the VM using the following addresses as
    # source address.
    ip6 saddr @private_ipv6_cidrs ct state established,related,new counter accept
    ip6 saddr ::/0 ct state established,related,new counter accept

    # Allow incoming traffic to the VM using the following addresses as
    # destination address. This is needed to allow the return traffic.
    ip6 daddr @private_ipv6_cidrs ct state established,related counter accept
    ip6 daddr ::/0 ct state established,related counter accept
    ip daddr @private_ipv4_cidrs ct state established,related counter accept

    # Allow ping for all
    ip saddr 0.0.0.0/0 icmp type echo-request counter accept
    ip daddr 0.0.0.0/0 icmp type echo-request counter accept
    ip saddr 0.0.0.0/0 icmp type echo-reply counter accept
    ip daddr 0.0.0.0/0 icmp type echo-reply counter accept
    ip6 saddr ::/0 icmpv6 type echo-request counter accept
    ip6 daddr ::/0 icmpv6 type echo-request counter accept
    ip6 saddr ::/0 icmpv6 type echo-reply counter accept
    ip6 daddr ::/0 icmpv6 type echo-reply counter accept

    # Allow load balancer traffic

  }
}
ADD_RULES
      expect { nx.update_firewall_rules }.to exit({"msg" => "firewall rule is added"})
    end
  end
end
