# frozen_string_literal: true

class Prog::CheckIpReachability < Prog::Base
  subject_is :sshable, :vm_host
  frame_accessor :failed_tries

  # Some providers put the host IP inside a VM subnet. The gateway of the
  # host is then in the VM pool too, and no VM can use it.
  label def start
    gateways = sshable.cmd_json("/usr/sbin/ip -j -4 route show default").filter_map { it["gateway"] }
    DB[:ipv4_address]
      .where(cidr: vm_host.assigned_subnets_dataset.select(:cidr), ip: gateways)
      .delete

    hop_check
  end

  label def check
    vm_ips = DB[:ipv4_address]
      .where(cidr: vm_host.assigned_subnets_dataset.select(:cidr))
      .order(:ip)
      .select_map { host(:ip) }
    host_ips = vm_host.assigned_host_addresses_dataset.where { {family(ip) => 4} }.order(:ip).select_map { host(:ip) }
    ips = host_ips + vm_ips

    unreachable = sshable.cmd_json("sudo host/bin/check-ip-reachability", stdin: ips.to_json).fetch("unreachable")
    if unreachable.empty?
      Page.from_tag_parts("UnreachableIpAddresses", vm_host.ubid)&.incr_resolve
      pop "all ip addresses are reachable"
    end

    self.failed_tries = (failed_tries || 0) + 1
    Clog.emit("unreachable ip addresses", {unreachable_ip_addresses: {vm_host: vm_host.ubid, unreachable:, failed_tries:}})
    if failed_tries >= 5
      Prog::PageNexus.assemble("#{vm_host.ubid} has unreachable IP addresses: #{unreachable.join(", ")}", ["UnreachableIpAddresses", vm_host.ubid], vm_host.ubid, resource_id: vm_host.id, extra_data: {unreachable:})
    end

    nap 60
  end
end
