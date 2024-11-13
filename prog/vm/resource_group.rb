# frozen_string_literal: true

class Prog::Vm::ResourceGroup < Prog::Base
  subject_is :resource_group

  semaphore :destroy
  
  def self.assemble_with_host(name, vm_host, allowed_cpus:, memory_1g:, type: "dedicated")
    fail "Must provide a VmHost." if vm_host.nil?
    fail "Must provide resource group name." if name.nil? || name.empty?
    fail "Resource group name cannot be 'user' or 'system'." if name == "user" || name == "system"
    fail "Resource group name cannot contain a hyphen (-)." if name.include?("-")

    ubid = ResourceGroup.generate_ubid

    DB.transaction do
      rg = ResourceGroup.create(
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
      rg.from_cpu_bitmask(ResourceGroup.cpuset_to_bitmask(allowed_cpus))  

      Strand.create(prog: "Vm::ResourceGroup", label: "prep") { _1.id = rg.id }
    end
  end

  def host
    @host ||= resource_group.vm_host
  end

  def rg
    resource_group
  end

  def before_run
    when_destroy_set? do
      if strand.label != "destroy"
        hop_destroy
      end
    end
  end

  label def prep
    case host.sshable.cmd("common/bin/daemonizer --check prep_#{rg.name}")
    when "Succeeded"
      host.sshable.cmd("common/bin/daemonizer --clean prep_#{rg.name}")
      rg.update(allocation_state: "accepting")
      hop_wait
    when "NotStarted", "Failed"
      host.sshable.cmd("common/bin/daemonizer 'sudo host/bin/setup-rg prep #{rg.inhost_name} \"#{rg.allowed_cpus}\"' prep_#{rg.name}")
    end

    nap 1
  end

  label def wait
    # TODO: add availabiltit checks
    # TODO: add re-checking the values after reboot
  
    nap 30
  end

  label def destroy
    decr_destroy

    resource_group.update(allocation_state: "draining")
    host.sshable.cmd("sudo host/bin/setup-rg delete #{rg.inhost_name}")
    resource_group.destroy

    pop "resource_group destroyed"
  end
end
