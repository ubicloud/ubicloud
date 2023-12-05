# frozen_string_literal: true

class Prog::Vnet::UpdateFirewallRules < Prog::Base
  subject_is :vm

  label def update_firewall_rules
    rules = vm.private_subnets.map(&:firewall_rules).flatten
    allowed_ingress_ip4 = rules.select { !_1.ip6? && !_1.port_range }.map { _1.ip.to_s }
    allowed_ingress_ip6 = rules.select { _1.ip6? && !_1.port_range }.map { _1.ip.to_s }
    allowed_ingress_ip4_port_set = generate_ip_port_set(rules.select { !_1.ip6? && _1.port_range })
    allowed_ingress_ip6_port_set = generate_ip_port_set(rules.select { _1.ip6? && _1.port_range })
    guest_ephemeral = subdivide_network(vm.ephemeral_net6).first.to_s
    vm.vm_host.sshable.cmd("sudo ip netns exec #{vm.inhost_name} nft --file -", stdin: <<TEMPLATE)
# An nftables idiom for idempotent re-create of a named entity: merge
# in an empty table (a no-op if the table already exists) and then
# delete, before creating with a new definition.
table inet fw_table;
delete table inet fw_table;
table inet fw_table {
  set allowed_ipv4_ips {
    type ipv4_addr;
    flags interval;
#{allowed_ingress_ip4.any? ? "elements = {#{allowed_ingress_ip4.join(",")}}" : ""}
  }

  set allowed_ipv6_ips {
    type ipv6_addr;
    flags interval;
#{allowed_ingress_ip6.any? ? "elements = {#{allowed_ingress_ip6.join(",")}}" : ""}
  }

  set allowed_ipv4_port_tuple {
    type ipv4_addr . inet_service;
    flags interval;
#{allowed_ingress_ip4_port_set.empty? ? "" : "elements = {#{allowed_ingress_ip4_port_set}}"}
  }

  set allowed_ipv6_port_tuple {
    type ipv6_addr . inet_service;
    flags interval;
#{allowed_ingress_ip6_port_set.empty? ? "" : "elements = {#{allowed_ingress_ip6_port_set}}"}
  }

  set private_ipv4_ips {
    type ipv4_addr;
    flags interval;
    elements = {
      #{generate_private_ip4_list}
    }
  }

  set private_ipv6_ips {
    type ipv6_addr
    flags interval
    elements = { #{generate_private_ip6_list} }
  }

  chain forward_ingress {
    type filter hook forward priority filter; policy drop;
    ip saddr @private_ipv4_ips ct state established,related,new counter accept
    ip daddr @private_ipv4_ips ct state established,related counter accept
    ip6 saddr @private_ipv6_ips ct state established,related,new counter accept
    ip6 daddr @private_ipv6_ips ct state established,related counter accept
    ip6 saddr #{guest_ephemeral} ct state established,related,new counter accept
    ip6 daddr #{guest_ephemeral} ct state established,related counter accept
    ip saddr @allowed_ipv4_ips ip daddr @private_ipv4_ips counter accept
    ip6 saddr @allowed_ipv6_ips ip6 daddr #{guest_ephemeral} counter accept
    ip saddr . tcp dport @allowed_ipv4_port_tuple ip daddr @private_ipv4_ips counter accept
    ip6 saddr . tcp dport @allowed_ipv6_port_tuple ip6 daddr #{guest_ephemeral} counter accept
    ip saddr . udp dport @allowed_ipv4_port_tuple ip daddr @private_ipv4_ips counter accept
    ip6 saddr . udp dport @allowed_ipv6_port_tuple ip6 daddr #{guest_ephemeral} counter accept
  }
}
TEMPLATE
    pop "firewall rule is added"
  end

  def generate_ip_port_set(rules)
    rules.map do |rule|
      ip = rule.ip.to_s
      port_range = rule.port_range
      port_rule = if port_range.begin == port_range.end - 1
        port_range.begin.to_s
      else
        "#{port_range.begin}-#{port_range.end - 1}"
      end

      "#{ip} . #{port_rule}"
    end.join(",")
  end

  def generate_private_ip4_list
    vm.nics.map { NetAddr::IPv4Net.parse(_1.private_ipv4.network.to_s + "/26").to_s }.join(",")
  end

  def generate_private_ip6_list
    vm.nics.map { NetAddr::IPv6Net.parse(_1.private_ipv6.network.to_s + "/64").to_s }.join(",")
  end

  def subdivide_network(net)
    prefix = net.netmask.prefix_len + 1
    halved = net.resize(prefix)
    [halved, halved.next_sib]
  end
end
