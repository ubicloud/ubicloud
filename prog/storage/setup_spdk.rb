# frozen_string_literal: true

class Prog::Storage::SetupSpdk < Prog::Base
  subject_is :sshable, :vm_host

  label def start
    sshable.cmd("sudo host/bin/setup-spdk install")
    pop "SPDK was setup"
  end
end
