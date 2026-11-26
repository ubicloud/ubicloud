# frozen_string_literal: true

class Prog::SetupNftables < Prog::Base
  subject_is :sshable, :vm_host

  # The blocked set holds the IPv4s a VM may take, dropping traffic to each
  # until one does. A subnet the host claims is never blocked. Some providers
  # put the host IP inside a VM subnet, so the host IPs also go to the allowed
  # set, which the host checks before the blocked set.
  label def start
    additional_subnets = vm_host.assigned_subnets_dataset
      .where { {family(cidr) => 4} }
      .exclude(id: AssignedHostAddress.select(:address_id))
      .all
    host_ips = vm_host.assigned_host_addresses_dataset
      .where { {family(ip) => 4} }
      .order(:ip)
      .select_map { host(:ip) }
    sshable.cmd("sudo host/bin/setup-nftables.rb :blocked :allowed", blocked: additional_subnets.map { it.cidr.to_s }.to_json, allowed: host_ips.to_json)

    pop "nftables was setup"
  end
end
