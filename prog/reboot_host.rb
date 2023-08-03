# frozen_string_literal: true

class Prog::RebootHost < Prog::Base
  subject_is :sshable, :vm_host

  def start
    vm_host.vms.each { |vm|
      vm.update(display_state: "rebooting host")
    }

    begin
      sshable.cmd("sudo reboot")
    rescue
    end

    hop :wait_reboot
  end

  def wait_reboot
    begin
      sshable.cmd("echo 1")
    rescue
      nap 15
    end

    hop :start_vms
  end

  def start_vms
    vm_host.vms.each { |vm|
      vm.incr_start_after_host_reboot
    }

    pop "host rebooted"
  end
end
