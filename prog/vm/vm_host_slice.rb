# frozen_string_literal: true

class Prog::Vm::VmHostSlice < Prog::Base
  subject_is :vm_host_slice

  semaphore :destroy, :start_after_host_reboot
  
  def self.assemble_with_host(name, vm_host, allowed_cpus:, memory_1g:, type: "dedicated")
    fail "Must provide a VmHost." if vm_host.nil?
    fail "Must provide slice name." if name.nil? || name.empty?
    fail "Slice name cannot be 'user' or 'system'." if name == "user" || name == "system"
    fail "Slice name cannot contain a hyphen (-)." if name.include?("-")

    ubid = VmHostSlice.generate_ubid

    DB.transaction do
      vm_host_slice = VmHostSlice.create(
        name: name,
        type: type,
        allowed_cpus: 0,
        cores: 0,
        total_cpu_percent: 0,
        used_cpu_percent: 0,
        total_memory_1g: memory_1g,
        used_memory_1g: 0,
        vm_host_id: vm_host.id
        ) { _1.id = ubid.to_uuid }

      # This validates the cpuset and updates or related values
      vm_host_slice.from_cpu_bitmask(VmHostSlice.cpuset_to_bitmask(allowed_cpus))  

      Strand.create(prog: "Vm::VmHostSlice", label: "prep") { _1.id = vm_host_slice.id }
    end
  end

  def host
    @host ||= vm_host_slice.vm_host
  end

  def before_run
    when_destroy_set? do
      if strand.label != "destroy"
        hop_destroy
      end
    end
  end

  label def prep
    case host.sshable.cmd("common/bin/daemonizer --check prep_#{vm_host_slice.name}")
    when "Succeeded"
      host.sshable.cmd("common/bin/daemonizer --clean prep_#{vm_host_slice.name}")
      vm_host_slice.update(enabled: true)
      hop_wait
    when "NotStarted", "Failed"
      host.sshable.cmd("common/bin/daemonizer 'sudo host/bin/setup-slice prep #{vm_host_slice.inhost_name} \"#{vm_host_slice.allowed_cpus}\"' prep_#{vm_host_slice.name}")
    end

    nap 1
  end

  label def wait
    # TODO: add availabiltit checks

    when_start_after_host_reboot_set? do
      register_deadline(:wait, 5 * 60)
      hop_start_after_host_reboot
    end

    nap 30
  end

  label def destroy
    decr_destroy

    vm_host_slice.update(enabled: false)
    host.sshable.cmd("sudo host/bin/setup-slice delete #{vm_host_slice.inhost_name}")
    vm_host_slice.destroy

    pop "vm_host_slice destroyed"
  end

  label def start_after_host_reboot
    host.sshable.cmd("sudo host/bin/setup-slice recreate-unpersisted #{vm_host_slice.inhost_name}")
    decr_start_after_host_reboot

    hop_wait
  end
end
