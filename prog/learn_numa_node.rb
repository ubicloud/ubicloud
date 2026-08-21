# frozen_string_literal: true

class Prog::LearnNumaNode < Prog::Base
  subject_is :sshable, :vm_host

  def self.assemble(vm_host_id)
    fail "No existing VmHost" unless VmHost[vm_host_id]

    Strand.create(prog: "LearnNumaNode", label: "start", stack: [{"subject_id" => vm_host_id}])
  end

  label def start
    if retval
      cpu_numa_nodes = retval.fetch("cpu_numa_nodes")
      cpus = VmHostCpu.where(vm_host_id: vm_host.id).all
      fail "VmHost has no vm_host_cpu rows to update" if cpus.empty?
      fail "lscpu reported #{cpu_numa_nodes.size} cpus, but VmHost has #{cpus.size} vm_host_cpu rows" if cpu_numa_nodes.size != cpus.size

      DB.transaction do
        cpus.each { it.update(numa_node: cpu_numa_nodes[it.cpu_number]) }
      end

      pop("updated numa_node for #{cpus.size} cpus")
    end

    push Prog::LearnCpu
  end
end
