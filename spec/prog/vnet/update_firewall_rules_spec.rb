# frozen_string_literal: true

RSpec.describe Prog::Vnet::UpdateFirewallRules do
  subject(:nx) {
    described_class.new(st)
  }

  let(:st) { Strand.new }
  let(:ps) {
    instance_double(PrivateSubnet)
  }
  let(:vm) {
    vmh = instance_double(VmHost, sshable: instance_double(Sshable, cmd: nil))
    nic = instance_double(Nic, private_ipv4: NetAddr::IPv4Net.parse("10.0.0.0/32"), private_ipv6: NetAddr::IPv6Net.parse("fd00::1/128"), ubid_to_tap_name: "tap0")
    ephemeral_net6 = NetAddr::IPv6Net.parse("fd00::1/79")
    instance_double(Vm, private_subnets: [ps], vm_host: vmh, inhost_name: "x", nics: [nic], ephemeral_net6: ephemeral_net6, load_balancer: nil, private_ipv4: NetAddr::IPv4Net.parse("10.0.0.0/32").network, location: Location[Location::HETZNER_FSN1_ID])
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
    it "hops to update_aws_firewall_rules if vm is aws" do
      expect(nx).to receive(:vm).and_return(vm).at_least(:once)
      expect(vm).to receive(:location).and_return(instance_double(Location, aws?: true))
      expect { nx.update_firewall_rules }.to hop("update_aws_firewall_rules")
    end

    it "populates elements if there are fw rules" do
      GloballyBlockedDnsname.create_with_id(dns_name: "blockedhost.com", ip_list: ["123.123.123.123", "2a00:1450:400e:811::200e"])
      expect(nx).to receive(:vm).and_return(vm).at_least(:once)
      expect(vm).to receive(:firewalls).and_return([instance_double(Firewall, name: "fw_table", firewall_rules: [
        instance_double(FirewallRule, ip6?: false, cidr: NetAddr::IPv4Net.parse("0.0.0.0/0"), port_range: nil),
        instance_double(FirewallRule, ip6?: false, cidr: NetAddr::IPv4Net.parse("1.1.1.1/32"), port_range: Sequel.pg_range(22..23)),
        instance_double(FirewallRule, ip6?: false, cidr: NetAddr::IPv4Net.parse("10.10.10.0/26"), port_range: Sequel.pg_range(80..10000)),
        instance_double(FirewallRule, ip6?: false, cidr: NetAddr::IPv4Net.parse("123.123.123.64/27"), port_range: Sequel.pg_range(8080..12000)),
        instance_double(FirewallRule, ip6?: false, cidr: NetAddr::IPv4Net.parse("123.123.123.64/26"), port_range: Sequel.pg_range(9000..16000)),
        instance_double(FirewallRule, ip6?: true, cidr: NetAddr::IPv6Net.parse("::/0"), port_range: nil),
        instance_double(FirewallRule, ip6?: true, cidr: NetAddr::IPv6Net.parse("fd00::1/128"), port_range: Sequel.pg_range(8080..65536)),
        instance_double(FirewallRule, ip6?: true, cidr: NetAddr::IPv6Net.parse("fd00::1/64"), port_range: Sequel.pg_range(0..8081)),
        instance_double(FirewallRule, ip6?: true, cidr: NetAddr::IPv6Net.parse("fd00::2/64"), port_range: Sequel.pg_range(80..10000))
      ])])

      expect(vm.vm_host.sshable).to receive(:cmd).with("sudo ip netns exec x nft --file -", stdin: <<ADD_RULES)
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
      10.0.0.0/32
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
      GloballyBlockedDnsname.create_with_id(dns_name: "blockedhost.com", ip_list: ["123.123.123.123", "2a00:1450:400e:811::200e"])
      expect(nx).to receive(:vm).and_return(vm).at_least(:once)
      expect(vm).to receive(:firewalls).and_return([instance_double(Firewall, name: "fw_table", firewall_rules: [
        instance_double(FirewallRule, ip6?: false, cidr: NetAddr::IPv4Net.parse("0.0.0.0/0"), port_range: nil),
        instance_double(FirewallRule, ip6?: false, cidr: NetAddr::IPv4Net.parse("1.1.1.1/32"), port_range: Sequel.pg_range(22..23)),
        instance_double(FirewallRule, ip6?: false, cidr: NetAddr::IPv4Net.parse("10.10.10.0/26"), port_range: Sequel.pg_range(80..10000)),
        instance_double(FirewallRule, ip6?: false, cidr: NetAddr::IPv4Net.parse("123.123.123.64/27"), port_range: Sequel.pg_range(8080..12000)),
        instance_double(FirewallRule, ip6?: false, cidr: NetAddr::IPv4Net.parse("123.123.123.64/26"), port_range: Sequel.pg_range(9000..16000)),
        instance_double(FirewallRule, ip6?: true, cidr: NetAddr::IPv6Net.parse("::/0"), port_range: nil),
        instance_double(FirewallRule, ip6?: true, cidr: NetAddr::IPv6Net.parse("fd00::1/128"), port_range: Sequel.pg_range(8080..65536)),
        instance_double(FirewallRule, ip6?: true, cidr: NetAddr::IPv6Net.parse("fd00::1/64"), port_range: Sequel.pg_range(0..8081)),
        instance_double(FirewallRule, ip6?: true, cidr: NetAddr::IPv6Net.parse("fd00::2/64"), port_range: Sequel.pg_range(80..10000))
      ])])
      expect(vm).to receive(:id).and_return(1).at_least(:once)
      vm2 = instance_double(Vm, id: 2, nics: [instance_double(Nic, private_ipv4: NetAddr::IPv4Net.parse("10.0.0.1/32"), private_ipv6: NetAddr::IPv6Net.parse("fd00::/124"))], private_ipv4: NetAddr::IPv4Net.parse("10.0.0.1/32").network, private_ipv6: NetAddr::IPv6.parse("fd00::2"))
      port = instance_double(LoadBalancerPort, src_port: 443, dst_port: 8443)
      lb = instance_double(LoadBalancer, name: "lb_table", ports: [port], vms: [vm, vm2])
      expect(vm).to receive(:load_balancer).and_return(lb).at_least(:once)
      allow(lb).to receive(:ports).and_return([{src_port: 443, dst_port: 8443}])
      expect(vm.vm_host.sshable).to receive(:cmd).with("sudo ip netns exec x nft --file -", stdin: <<ADD_RULES)
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
      10.0.0.0/32
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
ip saddr . tcp sport { 10.0.0.1 . 443 } ct state established,related,new counter accept
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
      GloballyBlockedDnsname.create_with_id(dns_name: "blockedhost.com", ip_list: ["123.123.123.123", "2a00:1450:400e:811::200e"])
      expect(nx).to receive(:vm).and_return(vm).at_least(:once)
      expect(vm).to receive(:firewalls).and_return([instance_double(Firewall, name: "fw_table", firewall_rules: [
        instance_double(FirewallRule, ip6?: false, cidr: NetAddr::IPv4Net.parse("0.0.0.0/0"), port_range: nil),
        instance_double(FirewallRule, ip6?: false, cidr: NetAddr::IPv4Net.parse("1.1.1.1/32"), port_range: Sequel.pg_range(22..23)),
        instance_double(FirewallRule, ip6?: false, cidr: NetAddr::IPv4Net.parse("10.10.10.0/26"), port_range: Sequel.pg_range(80..10000)),
        instance_double(FirewallRule, ip6?: false, cidr: NetAddr::IPv4Net.parse("123.123.123.64/27"), port_range: Sequel.pg_range(8080..12000)),
        instance_double(FirewallRule, ip6?: false, cidr: NetAddr::IPv4Net.parse("123.123.123.64/26"), port_range: Sequel.pg_range(9000..16000)),
        instance_double(FirewallRule, ip6?: true, cidr: NetAddr::IPv6Net.parse("::/0"), port_range: nil),
        instance_double(FirewallRule, ip6?: true, cidr: NetAddr::IPv6Net.parse("fd00::1/128"), port_range: Sequel.pg_range(8080..65536)),
        instance_double(FirewallRule, ip6?: true, cidr: NetAddr::IPv6Net.parse("fd00::1/64"), port_range: Sequel.pg_range(0..8081)),
        instance_double(FirewallRule, ip6?: true, cidr: NetAddr::IPv6Net.parse("fd00::2/64"), port_range: Sequel.pg_range(80..10000))
      ])])
      expect(vm).to receive(:id).and_return(1).at_least(:once)
      port = instance_double(LoadBalancerPort, src_port: 443, dst_port: 8443)
      lb = instance_double(LoadBalancer, name: "lb_table", ports: [port], vms: [vm])
      allow(lb).to receive(:ports).and_return([{src_port: 443, dst_port: 8443}])
      expect(vm).to receive(:load_balancer).and_return(lb).at_least(:once)
      expect(vm.vm_host.sshable).to receive(:cmd).with("sudo ip netns exec x nft --file -", stdin: <<ADD_RULES)
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
      10.0.0.0/32
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

    it "does not pass elements if there are not fw rules" do
      # An address to block but not discovered the ip_list, yet.
      GloballyBlockedDnsname.create_with_id(dns_name: "blockedhost.com", ip_list: nil)

      expect(nx).to receive(:vm).and_return(vm).at_least(:once)
      expect(vm).to receive(:firewalls).and_return([])
      expect(vm.vm_host.sshable).to receive(:cmd).with("sudo ip netns exec x nft --file -", stdin: <<ADD_RULES)
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
      10.0.0.0/32
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
  end

  describe "#update_aws_firewall_rules" do
    let(:ec2_client) { instance_double(Aws::EC2::Client) }

    before do
      lcred = instance_double(LocationCredential, client: ec2_client)
      loc = instance_double(Location, provider: "aws", location_credential: lcred)
      allow(nx).to receive(:vm).and_return(vm)
      allow(vm).to receive(:location).and_return(loc)
    end

    it "hops to remove_aws_firewall_rules if there are no fw rules to add" do
      expect(nx).to receive(:vm).and_return(vm).at_least(:once)
      expect(vm).to receive(:firewalls).and_return([])
      expect { nx.update_aws_firewall_rules }.to hop("remove_aws_old_rules")
    end

    it "hops to remove_aws_firewall_rules after adding new rules" do
      expect(nx).to receive(:vm).and_return(vm).at_least(:once)
      expect(vm).to receive(:firewalls).and_return([instance_double(Firewall, name: "fw_table", firewall_rules: [
        instance_double(FirewallRule, ip6?: false, cidr: NetAddr::IPv4Net.parse("0.0.0.0/0"), port_range: Sequel.pg_range(80..10000)),
        instance_double(FirewallRule, ip6?: false, cidr: NetAddr::IPv4Net.parse("1.1.1.1/32"), port_range: Sequel.pg_range(22..23)),
        instance_double(FirewallRule, ip6?: true, cidr: NetAddr::IPv6Net.parse("fd00::1/128"), port_range: Sequel.pg_range(80..10000))
      ])])
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

      expect { nx.update_aws_firewall_rules }.to hop("remove_aws_old_rules")
    end

    it "continues and hops to remove_aws_old_rules if there is a duplicate rule" do
      expect(nx).to receive(:vm).and_return(vm).at_least(:once)
      expect(vm).to receive(:firewalls).and_return([instance_double(Firewall, name: "fw_table", firewall_rules: [
        instance_double(FirewallRule, ip6?: false, cidr: NetAddr::IPv4Net.parse("0.0.0.0/0"), port_range: Sequel.pg_range(80..10000)),
        instance_double(FirewallRule, ip6?: false, cidr: NetAddr::IPv4Net.parse("1.1.1.1/32"), port_range: Sequel.pg_range(22..23)),
        instance_double(FirewallRule, ip6?: true, cidr: NetAddr::IPv6Net.parse("fd00::1/128"), port_range: Sequel.pg_range(80..10000))
      ])])
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

      expect { nx.update_aws_firewall_rules }.to hop("remove_aws_old_rules")
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
      expect(vm).to receive(:firewalls).and_return([instance_double(Firewall, name: "fw_table", firewall_rules: [
        instance_double(FirewallRule, ip6?: false, cidr: NetAddr::IPv4Net.parse("0.0.0.0/0"), port_range: Sequel.pg_range(80..10000)),
        instance_double(FirewallRule, ip6?: false, cidr: NetAddr::IPv4Net.parse("1.1.1.1/32"), port_range: Sequel.pg_range(22..23)),
        instance_double(FirewallRule, ip6?: true, cidr: NetAddr::IPv6Net.parse("fd00::1/128"), port_range: Sequel.pg_range(80..10000))
      ])])
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

      expect(ec2_client).to receive(:revoke_security_group_ingress).with({group_id: "sg-1234567890", ip_permissions: [{from_port: 0, ip_protocol: "tcp", ipv_6_ranges: [Aws::EC2::Types::Ipv6Range.new(cidr_ipv_6: "fd00::1/128")], to_port: 100}]})
      expect(ec2_client).to receive(:revoke_security_group_ingress).with({group_id: "sg-1234567890", ip_permissions: [{from_port: 0, ip_protocol: "tcp", ip_ranges: [Aws::EC2::Types::IpRange.new(cidr_ip: "10.10.10.10/32")], to_port: 100}]}).and_raise(Aws::EC2::Errors::InvalidPermissionNotFound.new("Duplicate", "Duplicate"))

      expect { nx.remove_aws_old_rules }.to exit({"msg" => "firewall rule is added"})
    end

    it "doesn't make a call if there are no old rules" do
      expect(nx).to receive(:vm).and_return(vm).at_least(:once)
      expect(vm).to receive(:firewalls).and_return([instance_double(Firewall, name: "fw_table", firewall_rules: [
        instance_double(FirewallRule, ip6?: false, cidr: NetAddr::IPv4Net.parse("0.0.0.0/0"), port_range: Sequel.pg_range(80..10000)),
        instance_double(FirewallRule, ip6?: false, cidr: NetAddr::IPv4Net.parse("1.1.1.1/32"), port_range: Sequel.pg_range(22..23)),
        instance_double(FirewallRule, ip6?: true, cidr: NetAddr::IPv6Net.parse("fd00::1/128"), port_range: Sequel.pg_range(80..10000))
      ])])
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
