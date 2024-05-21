# frozen_string_literal: true

class Prog::Vnet::UpdateLoadBalancer < Prog::Base
  subject_is :vm

  label def update_load_balancer
    target_vms = vm.load_balancers.first.active_vms
    target_ips_v4 = target_vms.map { _1.nics.first.private_ipv4 }.flatten
    vm_ipv4 = vm.ephemeral_net4.to_s
    map_text_v4 = target_ips_v4.map.with_index { |ip, i| "#{i} : #{ip}" }.join(", ")

    vm.vm_host.sshable.cmd("sudo ip netns exec #{vm.inhost_name} nft --file -", stdin: <<TEMPLATE)
table inet lb_table;
delete table inet lb_table;
table inet lb_table {
  set target_ips_v4 {
    type ipv4_addr;
    flags interval;
    elements = { #{target_ips_v4.reject { _1.network.to_s == vm.nics.first.private_ipv4.network.to_s }.join(", ")} }
  }

  chain prerouting {
    type nat hook prerouting priority -100; policy accept;
    ip daddr #{vm_ipv4} tcp dport 80 ct state established,related,new counter dnat to numgen random mod #{target_ips_v4.count} map { #{map_text_v4} }
  }

  chain postrouting {
    type nat hook postrouting priority 100; policy accept;
    ip daddr @target_ips_v4 tcp dport 80 ct state established,related,new counter snat to #{vm.nics.first.private_ipv4.network}
    ip saddr @target_ips_v4 tcp sport 80 ct state established,related counter snat to #{vm_ipv4}
  }
}
TEMPLATE

    pop "load balancer is updated"
  end
end
