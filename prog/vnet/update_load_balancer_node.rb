# frozen_string_literal: true

class Prog::Vnet::UpdateLoadBalancerNode < Prog::Base
  subject_is :vm

  def load_balancer
    @load_balancer ||= LoadBalancer[frame.fetch("load_balancer_id")]
  end

  def before_run
    pop "VM is destroyed" unless vm
  end

  label def update_load_balancer
    vm.load_balancer_vm_ports.select { |lvp| lvp.state == "detaching" }.sort_by(&:stack).each do |load_balancer_vm_port|
      load_balancer.remove_vm_port(load_balancer_vm_port)
    end

    # if there is literally no up resources to balance for, we simply not do
    # load balancing.
    hop_remove_load_balancer if load_balancer.active_vm_ports.count == 0

    vm.vm_host.sshable.cmd("sudo ip netns exec #{vm.inhost_name} nft --file -", stdin: generate_lb_based_nat_rules)
    pop "load balancer is updated"
  end

  label def remove_load_balancer
    vm.vm_host.sshable.cmd("sudo ip netns exec #{vm.inhost_name} nft --file -", stdin: generate_nat_rules(vm.ip4_string, vm.private_ipv4.to_s))

    pop "load balancer is removed"
  end

  def generate_lb_based_nat_rules
    active_vm_ports_uniq_by_port = load_balancer.active_vm_ports { |ds| ds.eager(:load_balancer_port, load_balancer_vm: {vm: :nics}) }
      .uniq(&:load_balancer_port_id)
      .sort_by { |vm_port| vm_port.load_balancer_port.src_port }
    public_ipv4 = vm.ip4_string
    public_ipv6 = vm.ip6_string
    private_ipv4 = vm.private_ipv4
    private_ipv6 = vm.private_ipv6
    neighbor_vms = load_balancer.active_vm_ports.reject { it.load_balancer_vm.vm_id == vm.id }.uniq { |row| row.load_balancer_vm.id }.map(&:vm)
    neighbor_ips_v4_set, neighbor_ips_v6_set = generate_lb_ip_set_definition(neighbor_vms)

    balance_mode_ip4, balance_mode_ip6 = if load_balancer.algorithm == "round_robin"
      ["numgen inc", "numgen inc"]
    elsif load_balancer.algorithm == "hash_based"
      ["jhash ip saddr . tcp sport . ip daddr . tcp dport", "jhash ip6 saddr . tcp sport . ip6 daddr . tcp dport"]
    else
      fail ArgumentError, "Unsupported load balancer algorithm: #{load_balancer.algorithm}"
    end

    ipv4_prerouting = if load_balancer.ipv4_enabled?
      active_vm_ports_uniq_by_port.map do |vm_port|
        port = vm_port.load_balancer_port
        ipv4_map_def = generate_lb_map_defs_ipv4(port)
        modulo = ipv4_map_def.count
        <<-IPV4_PREROUTING
ip daddr #{public_ipv4} tcp dport #{port.src_port} meta mark set 0x00B1C100D
ip daddr #{public_ipv4} tcp dport #{port.src_port} ct state established,related,new counter dnat to #{balance_mode_ip4} mod #{modulo} map { #{ipv4_map_def.join(", ")} }
ip daddr #{private_ipv4} tcp dport #{port.src_port} ct state established,related,new counter dnat to #{private_ipv4}:#{port.dst_port}
        IPV4_PREROUTING
      end.join("\n")
    end

    ipv6_prerouting = if load_balancer.ipv6_enabled?
      active_vm_ports_uniq_by_port.map do |vm_port|
        port = vm_port.load_balancer_port
        ipv6_map_def = generate_lb_map_defs_ipv6(port)
        modulo = ipv6_map_def.count
        <<-IPV6_PREROUTING
ip6 daddr #{public_ipv6} tcp dport #{port.src_port} meta mark set 0x00B1C100D
ip6 daddr #{public_ipv6} tcp dport #{port.src_port} ct state established,related,new counter dnat to #{balance_mode_ip6} mod #{modulo} map { #{ipv6_map_def.join(", ")} }
ip6 daddr #{private_ipv6} tcp dport #{port.src_port} ct state established,related,new counter dnat to [#{public_ipv6}]:#{port.dst_port}
        IPV6_PREROUTING
      end.join("\n")
    end

    sorted_ports = load_balancer.ports.sort_by { |port| port.src_port }
    ipv4_postrouting_rule = sorted_ports.map do |port|
      if load_balancer.ipv4_enabled?
        "ip daddr @neighbor_ips_v4 tcp dport #{port.src_port} ct state established,related,new counter snat to #{private_ipv4}"
      end
    end.join("\n")

    ipv6_postrouting_rule = sorted_ports.map do |port|
      if load_balancer.ipv6_enabled?
        "ip6 daddr @neighbor_ips_v6 tcp dport #{port.src_port} ct state established,related,new counter snat to #{private_ipv6}"
      end
    end.join("\n")

    <<TEMPLATE
table ip nat;
delete table ip nat;
table inet nat;
delete table inet nat;
table inet nat {
  set neighbor_ips_v4 {
    type ipv4_addr;
#{neighbor_ips_v4_set}
  }

  set neighbor_ips_v6 {
    type ipv6_addr;
#{neighbor_ips_v6_set}
  }

  chain prerouting {
    type nat hook prerouting priority dstnat; policy accept;
#{ipv4_prerouting}
#{ipv6_prerouting}

    # Basic NAT for public IPv4 to private IPv4
    ip daddr #{public_ipv4} dnat to #{private_ipv4}
  }

  chain postrouting {
    type nat hook postrouting priority srcnat; policy accept;
#{ipv4_postrouting_rule}
#{ipv6_postrouting_rule}

    # Basic NAT for private IPv4 to public IPv4
    ip saddr #{private_ipv4} ip daddr != { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16 } snat to #{public_ipv4}
    ip saddr #{private_ipv4} ip daddr #{private_ipv4} snat to #{public_ipv4}
  }
}
TEMPLATE
  end

  def generate_lb_ip_set_definition(neighbor_vms)
    return ["", ""] if neighbor_vms.empty?

    ["elements = {#{neighbor_vms.map(&:private_ipv4).join(", ")}}",
      "elements = {#{neighbor_vms.map(&:private_ipv6).join(", ")}}"]
  end

  def generate_lb_map_defs(current_port)
    items = load_balancer.active_vm_ports
      .select { |vm_port| vm_port.load_balancer_port.dst_port == current_port.dst_port }
      .map do |vm_port|
        address = yield vm_port
        port = (vm_port.load_balancer_vm.vm_id == vm.id) ? vm_port.load_balancer_port.dst_port : vm_port.load_balancer_port.src_port
        [address.to_s, port.to_i]
      end

    items.sort!.map!.with_index do |(address, port), index|
      "#{index} : #{address} . #{port}"
    end
  end

  def generate_lb_map_defs_ipv4(current_port)
    generate_lb_map_defs(current_port) do |vm_port|
      vm_port.load_balancer_vm.vm.private_ipv4
    end
  end

  def generate_lb_map_defs_ipv6(current_port)
    generate_lb_map_defs(current_port) do |vm_port|
      (vm_port.load_balancer_vm.vm_id == vm.id) ? vm.ip6 : vm_port.load_balancer_vm.vm.private_ipv6
    end
  end

  def generate_nat_rules(current_public_ipv4, current_private_ipv4)
    <<NAT
table ip nat;
delete table ip nat;
table inet nat;
delete table inet nat;
table ip nat {
  chain prerouting {
    type nat hook prerouting priority dstnat; policy accept;
    ip daddr #{current_public_ipv4} dnat to #{current_private_ipv4}
  }
  chain postrouting {
    type nat hook postrouting priority srcnat; policy accept;
    ip saddr #{current_private_ipv4} ip daddr != { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16 } snat to #{current_public_ipv4}
    ip saddr #{current_private_ipv4} ip daddr #{current_private_ipv4} snat to #{current_public_ipv4}
  }
}
NAT
  end
end
