# frozen_string_literal: true

class Prog::SetupNftables < Prog::Base
  subject_is :sshable, :vm_host

  # The blocked set holds the IPv4s a VM may take, dropping traffic to each
  # until one does. An address the host configures on its own NIC never enters
  # the allowed set, so blocking it would blackhole it for good.
  label def start
    additional_subnets = vm_host.assigned_subnets_dataset
      .where { {family(cidr) => 4} }
      .exclude(id: AssignedHostAddress.select(:address_id))
      .all
    sshable.cmd("sudo host/bin/setup-nftables.rb :json", json: additional_subnets.map { it.cidr.to_s }.to_json)

    pop "nftables was setup"
  end
end
