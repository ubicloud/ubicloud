# frozen_string_literal: true

class Prog::SetupSpdk < Prog::Base
  subject_is :sshable, :vm_host

  def start
    fail "Not enough hugepages" unless vm_host.total_hugepages_1g > vm_host.used_hugepages_1g
    sshable.cmd("sudo bin/setup-spdk")
    hop :start_service
  end

  def start_service
    sshable.cmd("sudo systemctl enable home-spdk-hugepages.mount")
    sshable.cmd("sudo systemctl enable spdk")

    sshable.cmd("sudo systemctl start spdk")

    vm_host.update(used_hugepages_1g: vm_host.used_hugepages_1g + 1)
    pop "SPDK was setup"
  end
end
