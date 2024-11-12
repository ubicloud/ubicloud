# frozen_string_literal: true

class Prog::Vm::ResourceGroup < Prog::Base
  subject_is :resource_group

  semaphore :destroy
  
  def self.assemble(name, allowed_cpus:, cores:, memory_1g:, type: "dedicated")
    # TODO: Hardcoded for now, we will have to calculate it from the allowed_cpus and cross-check with cores
    total_cpu_percent = cores * 200

    ubid = ResourceGroup.generate_ubid

    DB.transaction do
      rg = ResourceGroup.create(
        name: name,
        type: type,
        allowed_cpus: allowed_cpus,
        cores: cores,
        total_cpu_percent: total_cpu_percent,
        used_cpu_percent: 0,
        total_memory_1g: memory_1g,
        used_memory_1g: 0
        ) { _1.id = ubid.to_uuid }

      Strand.create(prog: "Vm::ResourceGroup", label: "create") { _1.id = rg.id }
    end
  end

  def before_run
    when_destroy_set? do
      if strand.label != "destroy"
        hop_destroy
      end
    end
  end

  label def create
    # TODO: Here we will associate the RG with a VmHost and a Vm
    hop_wait
  end

  label def wait
    # TODO: add availabiltit checks
    # TODO: add re-checking the values after reboot
  
    nap 30
  end

  label def destroy
    decr_destroy

    resource_group.update(allocation_state: "draining")

    resource_group.destroy
    pop "resource_group destroyed"
  end
end
