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
    nic = instance_double(Nic, private_ipv4: NetAddr::IPv4Net.parse("10.0.0.0/32"), private_ipv6: NetAddr::IPv6Net.parse("fd00::1/128"))
    ephemeral_net6 = NetAddr::IPv6Net.parse("fd00::1/79")
    instance_double(Vm, private_subnets: [ps], vm_host: vmh, inhost_name: "x", nics: [nic], ephemeral_net6: ephemeral_net6)
  }

  describe "update_firewall_rules" do
    it "populates elements if there are fw rules" do
      expect(nx).to receive(:vm).and_return(vm).at_least(:once)
      expect(ps).to receive(:firewall_rules).and_return([
        instance_double(FirewallRule, ip6?: false, ip: "0.0.0.0/0", port_range: nil),
        instance_double(FirewallRule, ip6?: false, ip: "1.1.1.1/32", port_range: Sequel.pg_range(22..23)),
        instance_double(FirewallRule, ip6?: true, ip: "::/0", port_range: nil),
        instance_double(FirewallRule, ip6?: true, ip: "fd00::1/128", port_range: Sequel.pg_range(8080..65536))
      ])
      expect(vm.vm_host.sshable).to receive(:cmd).with("sudo ip netns exec x nft --file -", stdin: <<ADD_RULES)
# An nftables idiom for idempotent re-create of a named entity: merge
# in an empty table (a no-op if the table already exists) and then
# delete, before creating with a new definition.
table inet fw_table;
delete table inet fw_table;
table inet fw_table {
  set allowed_ipv4_ips {
    type ipv4_addr;
    flags interval;
elements = {0.0.0.0/0}
  }

  set allowed_ipv6_ips {
    type ipv6_addr;
    flags interval;
elements = {::/0}
  }

  set allowed_ipv4_port_tuple {
    type ipv4_addr . inet_service;
    flags interval;
elements = {1.1.1.1/32 . 22}
  }

  set allowed_ipv6_port_tuple {
    type ipv6_addr . inet_service;
    flags interval;
elements = {fd00::1/128 . 8080-65535}
  }

  set private_ipv4_ips {
    type ipv4_addr;
    flags interval;
    elements = {
      10.0.0.0/26
    }
  }

  set private_ipv6_ips {
    type ipv6_addr
    flags interval
    elements = { fd00::/64 }
  }

  chain forward_ingress {
    type filter hook forward priority filter; policy drop;
    ip saddr @private_ipv4_ips ct state established,related,new counter accept
    ip daddr @private_ipv4_ips ct state established,related counter accept
    ip6 saddr @private_ipv6_ips ct state established,related,new counter accept
    ip6 daddr @private_ipv6_ips ct state established,related counter accept
    ip6 saddr fd00::/80 ct state established,related,new counter accept
    ip6 daddr fd00::/80 ct state established,related counter accept
    ip saddr @allowed_ipv4_ips ip daddr @private_ipv4_ips counter accept
    ip6 saddr @allowed_ipv6_ips ip6 daddr fd00::/80 counter accept
    ip saddr . tcp dport @allowed_ipv4_port_tuple ip daddr @private_ipv4_ips counter accept
    ip6 saddr . tcp dport @allowed_ipv6_port_tuple ip6 daddr fd00::/80 counter accept
    ip saddr . udp dport @allowed_ipv4_port_tuple ip daddr @private_ipv4_ips counter accept
    ip6 saddr . udp dport @allowed_ipv6_port_tuple ip6 daddr fd00::/80 counter accept
  }
}
ADD_RULES

      expect { nx.update_firewall_rules }.to exit({"msg" => "firewall rule is added"})
    end

    it "does not pass elements if there are not fw rules" do
      expect(nx).to receive(:vm).and_return(vm).at_least(:once)
      expect(ps).to receive(:firewall_rules).and_return([])
      expect(vm.vm_host.sshable).to receive(:cmd).with("sudo ip netns exec x nft --file -", stdin: <<ADD_RULES)
# An nftables idiom for idempotent re-create of a named entity: merge
# in an empty table (a no-op if the table already exists) and then
# delete, before creating with a new definition.
table inet fw_table;
delete table inet fw_table;
table inet fw_table {
  set allowed_ipv4_ips {
    type ipv4_addr;
    flags interval;

  }

  set allowed_ipv6_ips {
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

  set private_ipv4_ips {
    type ipv4_addr;
    flags interval;
    elements = {
      10.0.0.0/26
    }
  }

  set private_ipv6_ips {
    type ipv6_addr
    flags interval
    elements = { fd00::/64 }
  }

  chain forward_ingress {
    type filter hook forward priority filter; policy drop;
    ip saddr @private_ipv4_ips ct state established,related,new counter accept
    ip daddr @private_ipv4_ips ct state established,related counter accept
    ip6 saddr @private_ipv6_ips ct state established,related,new counter accept
    ip6 daddr @private_ipv6_ips ct state established,related counter accept
    ip6 saddr fd00::/80 ct state established,related,new counter accept
    ip6 daddr fd00::/80 ct state established,related counter accept
    ip saddr @allowed_ipv4_ips ip daddr @private_ipv4_ips counter accept
    ip6 saddr @allowed_ipv6_ips ip6 daddr fd00::/80 counter accept
    ip saddr . tcp dport @allowed_ipv4_port_tuple ip daddr @private_ipv4_ips counter accept
    ip6 saddr . tcp dport @allowed_ipv6_port_tuple ip6 daddr fd00::/80 counter accept
    ip saddr . udp dport @allowed_ipv4_port_tuple ip daddr @private_ipv4_ips counter accept
    ip6 saddr . udp dport @allowed_ipv6_port_tuple ip6 daddr fd00::/80 counter accept
  }
}
ADD_RULES
      expect { nx.update_firewall_rules }.to exit({"msg" => "firewall rule is added"})
    end
  end
end
