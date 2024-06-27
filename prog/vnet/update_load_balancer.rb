# frozen_string_literal: true

class Prog::Vnet::UpdateLoadBalancer < Prog::Base
  subject_is :vm

  # TODO:
  # 1. PROTOCOL
  # 2. PORT MAPPING
  # 3. HANDLE UPDATES PROPERLY IN ADDITION AND REMOVAL OF VMS
  # 4. HANDLE UPDATES PROPERLY IN ADDITION AND REMOVAL OF LOAD BALANCERS
  def load_balancer
    @load_balancer ||= LoadBalancer[frame.fetch("load_balancer_id")]
  end

  label def update_load_balancer
    unless load_balancer.vms.map(&:id).include?(vm.id)
      vm.vm_host.sshable.cmd("sudo ip netns exec #{vm.inhost_name} nft --file -", stdin: generate_nat_rules(vm.ephemeral_net4.to_s, vm.nics.first.private_ipv4.network.to_s))
      pop "load balancer is updated"
    end

    source_port = load_balancer.src_port
    destination_port = load_balancer.dst_port
    #protocol = load_balancer.protocol

    target_vms = vm.load_balancers.first.active_vms

    target_private_ips_v4 = target_vms.map { _1.nics.first.private_ipv4 }.flatten
    current_public_ipv4 = vm.ephemeral_net4.to_s
    current_private_ipv4 = vm.nics.first.private_ipv4.network.to_s
    map_text_v4 = target_private_ips_v4.map.with_index { |ip, i| "#{i} : #{ip} . #{destination_port}" }.join(", ")
    neighbors_v4 = target_private_ips_v4.reject { _1.network.to_s == current_private_ipv4 }
    neighbor_ips_v4_line = neighbors_v4.empty? ? "" : "elements = { #{neighbors_v4.join(", ")} }"

    current_public_ipv6 = vm.ephemeral_net6.nth(2).to_s
    target_private_ips_v6 = target_vms.map { _1.nics.first.private_ipv6.nth(2).to_s }.flatten
    current_private_ipv6 = vm.nics.first.private_ipv6.nth(2).to_s
    map_text_v6_pr = target_private_ips_v6.map.with_index { |ip, i| "#{i} : #{ip} . #{destination_port}" }.join(", ")
    neighbors_v6_pr = target_private_ips_v6.reject { _1 == current_private_ipv6 }
    neighbor_ips_v6_line_pr = neighbors_v6_pr.empty? ? "" : "elements = { #{neighbors_v6_pr.join(", ")} }"

    vm.vm_host.sshable.cmd("sudo ip netns exec #{vm.inhost_name} nft --file -", stdin: <<TEMPLATE)
table ip nat;
delete table ip nat;
table inet nat;
delete table inet nat;
table inet nat {
  set neighbor_ips_v4 {
    type ipv4_addr;
    flags interval;
    #{neighbor_ips_v4_line}
  }

  set neighbor_ips_v6 {
    type ipv6_addr;
    flags interval;
    #{neighbor_ips_v6_line_pr}
  }

  chain prerouting {
    type nat hook prerouting priority dstnat; policy accept;
    ip daddr #{current_public_ipv4} tcp dport #{source_port} ct state established,related,new counter dnat to numgen random mod #{target_private_ips_v4.count} map { #{map_text_v4} }
    ip6 daddr #{current_public_ipv6} tcp dport #{source_port} ct state established,related,new counter dnat to numgen random mod #{target_private_ips_v6.count} map { #{map_text_v6_pr} }
    ip daddr #{current_public_ipv4} dnat to #{current_private_ipv4}
  }

  chain postrouting {
    type nat hook postrouting priority srcnat; policy accept;
    ip daddr @neighbor_ips_v4 tcp dport #{destination_port} ct state established,related,new counter snat to #{current_private_ipv4}
    ip6 daddr @neighbor_ips_v6 tcp dport #{destination_port} ct state established,related,new counter snat to #{current_private_ipv6}
    ip saddr #{current_private_ipv4} ip daddr != { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16 } snat to #{current_public_ipv4}
    ip saddr #{current_private_ipv4} ip daddr #{current_private_ipv4} snat to #{current_public_ipv4}
  }
}
TEMPLATE

    pop "load balancer is updated"
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
