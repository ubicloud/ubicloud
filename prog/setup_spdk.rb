# frozen_string_literal: true

class Prog::SetupSpdk < Prog::Base
  subject_is :sshable, :vm_host

  def start
    sshable.cmd("sudo bin/setup-spdk")
    hop :enable_service
  end

  def enable_service
    sshable.cmd("sudo systemctl enable home-spdk-hugepages.mount")
    sshable.cmd("sudo systemctl enable spdk")

    pop "SPDK was setup"
  end
end
