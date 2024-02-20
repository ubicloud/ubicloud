# frozen_string_literal: true

class Prog::SetupNftables < Prog::Base
  subject_is :sshable, :vm_host

  label def start
    additional_subnets = vm_host.assigned_subnets.select { |a| a.cidr.version == 4 && a.cidr.network.to_s != vm_host.sshable.host }
    sshable.cmd("sudo host/bin/setup-nftables.rb #{additional_subnets.map { _1.cidr.to_s }.to_json.shellescape}")

    pop "nftables was setup"
  end
end
