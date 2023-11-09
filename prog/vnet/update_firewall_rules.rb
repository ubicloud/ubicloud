# frozen_string_literal: true

class Prog::Vnet::UpdateFirewallRules < Prog::Base
  subject_is :vm

  label def update_firewall_rules
    rules = vm.private_subnets.map(&:firewall_rules).flatten
    allowed_ingress_ip4 = rules.select { !_1.ip6? }.map { _1.ip.to_s }
    allowed_ingress_ip6 = rules.select { _1.ip6? }.map { _1.ip.to_s }

    vm.vm_host.sshable.cmd("sudo ip netns exec #{vm.inhost_name} nft --file -", stdin: <<TEMPLATE)
flush set inet fw_table allowed_ipv4_ips;
flush set inet fw_table allowed_ipv6_ips;
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
}
TEMPLATE
    pop "firewall rule is added"
  end
end
