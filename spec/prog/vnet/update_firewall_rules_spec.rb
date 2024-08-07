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
    instance_double(Vm, private_subnets: [ps], vm_host: vmh, inhost_name: "x", nics: [nic], ephemeral_net6: ephemeral_net6)
  }

  describe "update_firewall_rules" do
    it "populates elements if there are fw rules" do
      GloballyBlockedDnsname.create_with_id(dns_name: "blockedhost.com", ip_list: Sequel.lit("ARRAY['123.123.123.123'::inet, '2a00:1450:400e:811::200e'::inet]"))
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
  set allowed_ipv4_cidrs {
    type ipv4_addr;
    flags interval;
elements = {0.0.0.0/0}
  }

  set allowed_ipv6_cidrs {
    type ipv6_addr;
    flags interval;
elements = {::/0}
  }

  set allowed_ipv4_port_tuple {
    type ipv4_addr . inet_service;
    flags interval;
elements = {1.1.1.1/32 . 22,10.10.10.0/26 . 80-9999,123.123.123.64/26 . 9000-15999,123.123.123.64/27 . 8080-8999}
  }

  set allowed_ipv6_port_tuple {
    type ipv6_addr . inet_service;
    flags interval;
elements = {fd00::/64 . 0-9999,fd00::1/128 . 10000-65535}
  }

  set private_ipv4_cidrs {
    type ipv4_addr;
    flags interval;
    elements = {
      10.0.0.0/26
    }
  }

  set private_ipv6_cidrs {
    type ipv6_addr
    flags interval
    elements = { fd00::/64 }
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

  flowtable ubi_flowtable {
    hook ingress priority filter
    devices = { tap0 }
  }

  chain forward_ingress {
    type filter hook forward priority filter; policy drop;
    meta l4proto { tcp, udp } flow offload @ubi_flowtable
    meta l4proto { tcp, udp } th dport 111 drop
    ip saddr @globally_blocked_ipv4s drop
    ip6 saddr @globally_blocked_ipv6s drop
    ip daddr @globally_blocked_ipv4s drop
    ip6 daddr @globally_blocked_ipv6s drop
    ip saddr @private_ipv4_cidrs ct state established,related,new counter accept
    ip daddr @private_ipv4_cidrs ct state established,related counter accept
    ip6 saddr @private_ipv6_cidrs ct state established,related,new counter accept
    ip6 daddr @private_ipv6_cidrs ct state established,related,new counter accept
    ip6 saddr fd00::/80 ct state established,related,new counter accept
    ip6 daddr fd00::/80 ct state established,related,new counter accept
    ip saddr @allowed_ipv4_cidrs ip daddr @private_ipv4_cidrs counter accept
    ip6 saddr @allowed_ipv6_cidrs ip6 daddr fd00::/80 counter accept
    ip saddr . tcp dport @allowed_ipv4_port_tuple ip daddr @private_ipv4_cidrs counter accept
    ip6 saddr . tcp dport @allowed_ipv6_port_tuple ip6 daddr fd00::/80 counter accept
    ip saddr . udp dport @allowed_ipv4_port_tuple ip daddr @private_ipv4_cidrs counter accept
    ip6 saddr . udp dport @allowed_ipv6_port_tuple ip6 daddr fd00::/80 counter accept
    ip saddr 0.0.0.0/0 icmp type echo-request counter accept
    ip6 saddr ::/0 icmpv6 type echo-request counter accept
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
  set allowed_ipv4_cidrs {
    type ipv4_addr;
    flags interval;

  }

  set allowed_ipv6_cidrs {
    type ipv6_addr;
    flags interval;

  }

  set allowed_ipv4_port_tuple {
    type ipv4_addr . inet_service;
    flags interval;

  }

  set allowed_ipv6_port_tuple {
    type ipv6_addr . inet_service;
    flags interval;

  }

  set private_ipv4_cidrs {
    type ipv4_addr;
    flags interval;
    elements = {
      10.0.0.0/26
    }
  }

  set private_ipv6_cidrs {
    type ipv6_addr
    flags interval
    elements = { fd00::/64 }
  }

  set globally_blocked_ipv4s {
    type ipv4_addr;
    flags interval;

  }

  set globally_blocked_ipv6s {
    type ipv6_addr;
    flags interval;

  }

  flowtable ubi_flowtable {
    hook ingress priority filter
    devices = { tap0 }
  }

  chain forward_ingress {
    type filter hook forward priority filter; policy drop;
    meta l4proto { tcp, udp } flow offload @ubi_flowtable
    meta l4proto { tcp, udp } th dport 111 drop
    ip saddr @globally_blocked_ipv4s drop
    ip6 saddr @globally_blocked_ipv6s drop
    ip daddr @globally_blocked_ipv4s drop
    ip6 daddr @globally_blocked_ipv6s drop
    ip saddr @private_ipv4_cidrs ct state established,related,new counter accept
    ip daddr @private_ipv4_cidrs ct state established,related counter accept
    ip6 saddr @private_ipv6_cidrs ct state established,related,new counter accept
    ip6 daddr @private_ipv6_cidrs ct state established,related,new counter accept
    ip6 saddr fd00::/80 ct state established,related,new counter accept
    ip6 daddr fd00::/80 ct state established,related,new counter accept
    ip saddr @allowed_ipv4_cidrs ip daddr @private_ipv4_cidrs counter accept
    ip6 saddr @allowed_ipv6_cidrs ip6 daddr fd00::/80 counter accept
    ip saddr . tcp dport @allowed_ipv4_port_tuple ip daddr @private_ipv4_cidrs counter accept
    ip6 saddr . tcp dport @allowed_ipv6_port_tuple ip6 daddr fd00::/80 counter accept
    ip saddr . udp dport @allowed_ipv4_port_tuple ip daddr @private_ipv4_cidrs counter accept
    ip6 saddr . udp dport @allowed_ipv6_port_tuple ip6 daddr fd00::/80 counter accept
    ip saddr 0.0.0.0/0 icmp type echo-request counter accept
    ip6 saddr ::/0 icmpv6 type echo-request counter accept
  }
}
ADD_RULES
      expect { nx.update_firewall_rules }.to exit({"msg" => "firewall rule is added"})
    end
  end
end
