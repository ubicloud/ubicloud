# frozen_string_literal: true

class Prog::Vnet::UpdateFirewallRules < Prog::Base
  subject_is :vm

  FirewallRuleObj = Struct.new(:cidr, :port_range)

  label def update_firewall_rules
    rules = vm.firewalls.map(&:firewall_rules).flatten
    allowed_ingress_ip4 = NetAddr.summ_IPv4Net(rules.select { !_1.ip6? && !_1.port_range }.map { _1.cidr }).map(&:to_s)
    allowed_ingress_ip6 = NetAddr.summ_IPv6Net(rules.select { _1.ip6? && !_1.port_range }.map { _1.cidr }).map(&:to_s)
    allowed_ingress_ip4_port_set = consolidate_rules(rules.select { !_1.ip6? && _1.port_range })
    allowed_ingress_ip6_port_set = consolidate_rules(rules.select { _1.ip6? && _1.port_range })
    guest_ephemeral, clover_ephemeral = subdivide_network(vm.ephemeral_net6).map(&:to_s)

    globally_blocked_ipv4s, globally_blocked_ipv6s = generate_globally_blocked_lists

    vm.vm_host.sshable.cmd("sudo ip netns exec #{vm.inhost_name} nft --file -", stdin: <<TEMPLATE)
# An nftables idiom for idempotent re-create of a named entity: merge
# in an empty table (a no-op if the table already exists) and then
# delete, before creating with a new definition.
table inet fw_table;
delete table inet fw_table;
table inet fw_table {
  set allowed_ipv4_cidrs {
    type ipv4_addr;
    flags interval;
#{allowed_ingress_ip4.any? ? "elements = {#{allowed_ingress_ip4.join(",")}}" : ""}
  }

  set allowed_ipv6_cidrs {
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

  set private_ipv4_cidrs {
    type ipv4_addr;
    flags interval;
    elements = {
      #{generate_private_ip4_list}
    }
  }

  set private_ipv6_cidrs {
    type ipv6_addr
    flags interval
    elements = { #{generate_private_ip6_list} }
  }

  set globally_blocked_ipv4s {
    type ipv4_addr;
    flags interval;
#{globally_blocked_ipv4s.empty? ? "" : "elements = {#{globally_blocked_ipv4s}}"}
  }

  set globally_blocked_ipv6s {
    type ipv6_addr;
    flags interval;
#{globally_blocked_ipv6s.empty? ? "" : "elements = {#{globally_blocked_ipv6s}}"}
  }

  flowtable ubi_flowtable {
    hook ingress priority filter
    devices = { #{vm.nics.map(&:ubid_to_tap_name).join(",")} }
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

    # If we are using clover_ephemeral, that means we are using ipsec. We need
    # to allow traffic for the private communication and block via firewall
    # rules through @allowed_ipv4_port_tuple and @allowed_ipv6_port_tuple in the
    # next section of rules.
    ip6 daddr #{clover_ephemeral} counter accept
    ip6 saddr #{clover_ephemeral} counter accept
    ip6 saddr @private_ipv6_cidrs ct state established,related,new counter accept
    ip6 saddr #{guest_ephemeral} ct state established,related,new counter accept

    # Allow incoming traffic to the VM using the following addresses as
    # destination address. This is needed to allow the return traffic.
    ip6 daddr @private_ipv6_cidrs ct state established,related counter accept
    ip6 daddr #{guest_ephemeral} ct state established,related counter accept
    ip6 daddr #{clover_ephemeral} ct state established,related counter accept
    ip daddr @private_ipv4_cidrs ct state established,related counter accept
    ip saddr 0.0.0.0/0 icmp type echo-request counter accept
    ip6 saddr ::/0 icmpv6 type echo-request counter accept
  }
}
TEMPLATE

    pop "firewall rule is added"
  end

  def generate_globally_blocked_lists
    globally_blocked_ipv4s = []
    globally_blocked_ipv6s = []

    GloballyBlockedDnsname.each do |globally_blocked_dnsname|
      ips = globally_blocked_dnsname.ip_list || []
      ips.each do |ip|
        globally_blocked_ipv4s << "#{ip}/32" if ip.ipv4?
        globally_blocked_ipv6s << "#{ip}/128" if ip.ipv6?
      end
    end
    summ_ipv4 = NetAddr.summ_IPv4Net(globally_blocked_ipv4s.map { NetAddr::IPv4Net.parse(_1.to_s) })
    summ_ipv6 = NetAddr.summ_IPv6Net(globally_blocked_ipv6s.map { NetAddr::IPv6Net.parse(_1.to_s) })
    [summ_ipv4.join(", "), summ_ipv6.join(", ")]
  end

  # This method is needed to properly consolidate port_ranges + cidrs.
  # For example, if we have the following rules:
  # 1. 10.10.10.8/29 . 80-8080
  # 2. 10.10.10.0/27 . 5432-10000
  #
  # We can't just merge the cidrs because the port ranges overlap. We need to
  # first identify where the overlap is in the port ranges and then merge the
  # cidrs for the overlapping port ranges. The result should be:
  # 1. 10.10.10.8/29 . 80-5431
  # 2. 10.10.10.0/27 . 5432-10000
  #
  # In the processing of these 2 rules, we first identify the port segments as;
  # 1. 80-5431
  # 2. 5432-8080
  # 3. 8081-10000
  #
  # Then we identify the cidrs for each segment:
  # 1. 10.10.10.8/29 (This is simply used from the first rule because the first
  #    rule is the only rule that has a cidr that overlaps with this segment)
  # 2. 10.10.10.8/29 + 10.10.10.0/27: The combination of these will result in
  #    10.10.10.0/27
  # 3. 10.10.10.0/27 (This is simply used from the second rule because the
  #    second rule is the only rule that has a cidr that overlaps with this
  #    segment)
  #
  # For the combination of the cidrs, we use the summ_IPv4/6Net method from the
  # netaddr gem. This method will combine the cidrs and remove any duplicates.
  # If we don't perform this combination, we will end up with an error from
  # nftables saying file exists.
  #
  # Additionally, the customers may have thousands of rules and possibly, they
  # overlap. We want to minimize the number of rules that we create on the
  # nftables side to avoid performance issues.
  def consolidate_rules(rules)
    port_segments = create_port_segments(rules)
    consolidated_rules = []

    port_segments.each do |segment|
      # Find rules that overlap with the current segment
      overlapping_rules = rules.select do |r|
        r.port_range.begin <= segment[:end] && r.port_range.end - 1 >= segment[:begin]
      end

      # Merge cidrs for overlapping rules
      merged_cidrs = if rules.first.cidr.version == 4
        NetAddr.summ_IPv4Net(overlapping_rules.map(&:cidr))
      else
        NetAddr.summ_IPv6Net(overlapping_rules.map(&:cidr))
      end
      merged_cidrs.each do |cidr|
        consolidated_rules << FirewallRuleObj.new(cidr, {begin: segment[:begin], end: segment[:end] + 1})
      end
    end

    combined_rules = combine_continuous_ranges_for_same_subnet(consolidated_rules)
    combined_rules.map do |r|
      if r.port_range[:begin] != r.port_range[:end] - 1
        "#{r.cidr} . #{r.port_range[:begin]}-#{r.port_range[:end] - 1}"
      else
        "#{r.cidr} . #{r.port_range[:begin]}"
      end
    end.join(",")
  end

  def combine_continuous_ranges_for_same_subnet(rules)
    rules.sort_by { |r| [r.cidr.to_s, r.port_range[:begin]] }.chunk_while { |a, b| a.cidr.to_s == b.cidr.to_s && a.port_range[:end] == b.port_range[:begin] }.map do |chunk|
      if chunk.size > 1
        FirewallRuleObj.new(chunk.first.cidr, {begin: chunk.first.port_range[:begin], end: chunk.last.port_range[:end]})
      else
        chunk.first
      end
    end
  end

  def create_port_segments(rules)
    # Extract unique start and end points from port ranges
    points = rules.flat_map { |r| [r.port_range.begin.to_i, r.port_range.end.to_i] }.uniq.sort
    segments = []

    # Create segments based on unique points
    points.each_cons(2) do |start_point, end_point|
      segments << {begin: start_point, end: end_point - 1}
    end

    segments
  end

  def generate_private_ip4_list
    vm.nics.map { _1.private_ipv4.to_s }.join(",")
  end

  def generate_private_ip6_list
    vm.nics.map { _1.private_ipv6.to_s }.join(",")
  end

  def subdivide_network(net)
    prefix = net.netmask.prefix_len + 1
    halved = net.resize(prefix)
    [halved, halved.next_sib]
  end
end
