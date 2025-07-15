# frozen_string_literal: true

class Prog::Vm::VmHostSliceNexus < Prog::Base
  subject_is :vm_host_slice

  def self.assemble_with_host(name, vm_host, family:, allowed_cpus:, memory_gib:, is_shared: false)
    DB.transaction do
      vm_host_slice = VmHostSlice.create(
        name: name,
        is_shared: is_shared,
        family: family,
        cores: 0,
        total_cpu_percent: 0,
        used_cpu_percent: 0,
        total_memory_gib: memory_gib,
        used_memory_gib: 0,
        vm_host_id: vm_host.id
      )

      # This will update the CPU allocation as well as total_cpu_percent and cores values
      vm_host_slice.set_allowed_cpus(allowed_cpus)

      Strand.create(prog: "Vm::VmHostSliceNexus", label: "prep") { it.id = vm_host_slice.id }
    end
  end

  def host
    @host ||= vm_host_slice.vm_host
  end

  def before_run
    when_destroy_set? do
      hop_destroy if strand.label != "destroy"
    end
  end

  label def prep
    case host.sshable.cmd("common/bin/daemonizer --check prep_#{vm_host_slice.name}")
    when "Succeeded"
      host.sshable.cmd("common/bin/daemonizer --clean prep_#{vm_host_slice.name}")
      hop_wait
    when "NotStarted", "Failed"
      host.sshable.cmd("common/bin/daemonizer 'sudo host/bin/setup-slice prep #{vm_host_slice.inhost_name} \"#{vm_host_slice.allowed_cpus_cgroup}\"' prep_#{vm_host_slice.name}")
    end

    nap 1
  end

  label def wait
    when_start_after_host_reboot_set? do
      register_deadline(:wait, 5 * 60)
      hop_start_after_host_reboot
    end

    when_checkup_set? do
      hop_unavailable if !available?
      decr_checkup
    rescue Sshable::SshError
      # Host is likely to be down, which will be handled by HostNexus. We still
      # go to the unavailable state for keeping track of the state.
      hop_unavailable
    end

    nap 6 * 60 * 60
  end

  label def unavailable
    # If the slice becomes unavailable due to host unavailability, it first needs to
    # go through start_after_host_reboot state to be able to recover.
    when_start_after_host_reboot_set? do
      incr_checkup
      hop_start_after_host_reboot
    end

    begin
      if available?
        decr_checkup
        hop_wait
      else
        # Use deadlines to create a page instead of a custom page, so page
        # resolution in different states can be handled properly.
        register_deadline("wait", 0)
      end
    rescue *Sshable::SSH_CONNECTION_ERRORS
      # Host is likely to be down, which will be handled by HostNexus. No need
      # to create a page for this case.
    end

    nap 30
  end

  label def destroy
    decr_destroy

    host.sshable.cmd("sudo host/bin/setup-slice delete #{vm_host_slice.inhost_name}")

    VmHost.dataset.where(id: host.id).update(
      used_cores: Sequel[:used_cores] - vm_host_slice.cores,
      used_hugepages_1g: Sequel[:used_hugepages_1g] - vm_host_slice.total_memory_gib
    )

    vm_host_slice.destroy

    pop "vm_host_slice destroyed"
  end

  label def start_after_host_reboot
    host.sshable.cmd("sudo host/bin/setup-slice recreate-unpersisted #{vm_host_slice.inhost_name}")
    decr_start_after_host_reboot

    hop_wait
  end

  def available?
    available = false
    host.sshable.start_fresh_session do |session|
      available = vm_host_slice.up? session
    end

    available
  end
end
