# frozen_string_literal: true

class Prog::LearnCpuTopology < Prog::Base
  subject_is :sshable, :vm_host

  def self.assemble(vm_host_id)
    fail "No existing VmHost" unless VmHost[vm_host_id]

    Strand.create(prog: "LearnCpuTopology", label: "start", stack: [{"subject_id" => vm_host_id}])
  end

  label def start
    if retval
      cpu_numa_nodes = retval.fetch("cpu_numa_nodes")
      cpu_cores = retval.fetch("cpu_cores")
      cpus = vm_host.cpus_dataset
      cpu_count = cpus.count
      fail "VmHost has no vm_host_cpu rows to update" if cpu_count.zero?
      fail "lscpu reported #{cpu_cores.size} cpus, but VmHost has #{cpu_count} vm_host_cpu rows" if cpu_cores.size != cpu_count

      numa_node_by_cpu_number = cpu_numa_nodes.each_with_index.to_h { |numa_node, cpu_number| [cpu_number, numa_node] }
      core_number_by_cpu_number = cpu_cores.each_with_index.to_h { |core_number, cpu_number| [cpu_number, core_number] }
      cpus.update(
        # Without numa data every branch is NULL, which PostgreSQL types as text.
        numa_node: Sequel.case(numa_node_by_cpu_number, nil, :cpu_number).cast(:integer),
        core_number: Sequel.case(core_number_by_cpu_number, nil, :cpu_number),
      )

      pop("updated numa_node and core_number for #{cpu_count} cpus")
    end

    push Prog::LearnCpu
  end
end
