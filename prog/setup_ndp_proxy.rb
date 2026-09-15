# frozen_string_literal: true

class Prog::SetupNdpProxy < Prog::Base
  subject_is :sshable, :vm_host

  label def start
    pop "ndp proxy not needed" unless vm_host.ndp_needed

    register_deadline(nil, 10 * 60)

    unless vm_host.net6
      nap 5 if learn_network_running?

      Prog::PageNexus.assemble("#{vm_host.ubid} needs the NDP proxy but has no net6", ["NdpProxyNoNet6", vm_host.ubid], vm_host.ubid, resource_id: vm_host.id)
      pop "ndp proxy skipped: no net6"
    end

    sshable.cmd("sudo host/bin/setup-ndp-proxy install :net6", net6: vm_host.net6.to_s)
    Page.from_tag_parts("NdpProxyNoNet6", vm_host.ubid)&.incr_resolve

    pop "ndp proxy was setup"
  end

  # A LearnNetwork budded next to this strand is the only thing that can
  # still fill net6 in; the detached rollout has no parent and no sibling.
  def learn_network_running?
    return false unless strand.parent_id

    !Strand.where(parent_id: strand.parent_id, prog: "LearnNetwork", exitval: nil).empty?
  end
end
