# frozen_string_literal: true

class Prog::SetupNdpProxy < Prog::Base
  subject_is :sshable, :vm_host

  label def start
    pop "ndp proxy not needed" unless vm_host.ndp_needed

    unless vm_host.net6
      # LearnNetwork is budded alongside this prog and fills net6 in, so the
      # program's prefix guard has to wait for it rather than skip the host.
      # It can also pop having learned nothing, which leaves nothing else to
      # bound the wait.
      register_deadline(nil, 10 * 60)
      nap 5
    end

    sshable.cmd("sudo host/bin/setup-ndp-proxy install :net6", net6: vm_host.net6.to_s)

    pop "ndp proxy was setup"
  end
end
