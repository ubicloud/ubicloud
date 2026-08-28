# frozen_string_literal: true

class Prog::LearnHypervisor < Prog::Base
  subject_is :vm

  def self.assemble(vm_id)
    fail "No existing Vm" unless Vm[vm_id]

    Strand.create(prog: "LearnHypervisor", label: "start", stack: [{"subject_id" => vm_id}])
  end

  label def start
    register_deadline("start", 30 * 60)

    pop "exiting as Vm destroyed" unless vm
    inhost_name = vm.inhost_name
    unit = vm.vm_host.sshable.cmd("sudo cat /etc/systemd/system/:inhost_name.service", inhost_name:)

    hypervisor = if (version = unit[%r{/opt/cloud-hypervisor/v([^/]+)/cloud-hypervisor}, 1])
      Hypervisor.first(name: "ch", version:)
    elsif unit.include?("qemu-system-")
      Hypervisor.first(name: "qemu")
    end

    fail "Could not determine hypervisor in use for #{vm}" unless hypervisor

    vm.update(hypervisor_id: hypervisor.id)
    pop "learned #{[hypervisor.name, hypervisor.version].compact.join(" ")} for #{vm}"
  end
end
