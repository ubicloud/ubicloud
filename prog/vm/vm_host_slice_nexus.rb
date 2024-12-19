# frozen_string_literal: true

class Prog::Vm::VmHostSliceNexus < Prog::Base
  subject_is :vm_host_slice

  semaphore :destroy, :start_after_host_reboot, :checkup

  def self.assemble_with_host(name, vm_host, family:, allowed_cpus:, memory_gib:, type: "dedicated")
    fail "Must provide a VmHost." if vm_host.nil?
    fail "Must provide slice name." if name.nil? || name.empty?
    fail "Must provide family name." if family.nil? || family.empty?
    fail "Slice name cannot be 'user' or 'system'." if name == "user" || name == "system"
    fail "Slice name cannot contain a hyphen (-)." if name.include?("-")

    ubid = VmHostSlice.generate_ubid

    DB.transaction do
      vm_host_slice = VmHostSlice.create(
        name: name,
        type: type,
        cores: 0,
        total_cpu_percent: 0,
        used_cpu_percent: 0,
        total_memory_gib: memory_gib,
        used_memory_gib: 0,
        vm_host_id: vm_host.id
      ) { _1.id = ubid.to_uuid }

      vm_host_slice.set_allowed_cpus(allowed_cpus)

      Strand.create(prog: "Vm::VmHostSliceNexus", label: "prep") { _1.id = vm_host_slice.id }
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

    nap 30
  end

  label def unavailable
    # If the slice become unavailable due to host unavailability, it first needs to
    # go through start_after_host_reboot state to be able to recover.
    when_start_after_host_reboot_set? do
      incr_checkup
      hop_start_after_host_reboot
    end

    begin
      if available?
        Page.from_tag_parts("VmHostSliceUnavailable", vm_host_slice.ubid)&.incr_resolve
        decr_checkup
        hop_wait
      else
        Prog::PageNexus.assemble("#{vm_host_slice.inhost_name} is unavailable", ["VmHostSliceUnavailable", vm_host_slice.ubid], vm_host_slice.ubid)
      end
    rescue Sshable::SshError
      # Host is likely to be down, which will be handled by HostNexus. No need
      # to create a page for this case.
    end

    nap 30
  end

  label def destroy
    decr_destroy

    vm_host_slice.update(enabled: false)

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
    host.sshable.cmd("systemctl is-active #{vm_host_slice.inhost_name}").split("\n").all?("active") &&
      (host.sshable.cmd("cat /sys/fs/cgroup/#{vm_host_slice.inhost_name}/cpuset.cpus.effective").chomp == vm_host_slice.allowed_cpus_cgroup) &&
      (host.sshable.cmd("cat /sys/fs/cgroup/#{vm_host_slice.inhost_name}/cpuset.cpus.partition").chomp == "root")
  end
end
