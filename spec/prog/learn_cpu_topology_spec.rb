# frozen_string_literal: true

require_relative "../model/spec_helper"

RSpec.describe Prog::LearnCpuTopology do
  subject(:nx) { described_class.new(described_class.assemble(vm_host.id)) }

  let(:vm_host) { create_vm_host }

  describe ".assemble" do
    it "fails if the VmHost does not exist" do
      expect {
        described_class.assemble(VmHost.generate_uuid)
      }.to raise_error RuntimeError, "No existing VmHost"
    end

    it "creates a strand pointed at the given VmHost" do
      st = described_class.assemble(vm_host.id)
      expect(st).to be_a Strand
      expect(st.prog).to eq "LearnCpuTopology"
      expect(st.label).to eq "start"
      expect(described_class.new(st).vm_host.id).to eq vm_host.id
    end
  end

  describe "#start" do
    it "pushes LearnCpu when there is no retval yet" do
      expect { nx.start }.to hop("start", "LearnCpu")
    end

    it "fails if the VmHost has no vm_host_cpu rows" do
      nx.strand.retval = {"cpu_numa_nodes" => [0, 0, 1, 1], "cpu_cores" => [0, 1, 0, 1]}
      expect { nx.start }.to raise_error RuntimeError, "VmHost has no vm_host_cpu rows to update"
    end

    it "fails if lscpu reports a different cpu count than vm_host_cpu has rows for" do
      VmHostCpu.create(vm_host_id: vm_host.id, cpu_number: 0, io: false)
      nx.strand.retval = {"cpu_numa_nodes" => [0, 0, 1, 1], "cpu_cores" => [0, 1, 0, 1]}
      expect {
        nx.start
      }.to raise_error RuntimeError, "lscpu reported 4 cpus, but VmHost has 1 vm_host_cpu rows"
    end

    it "updates numa_node and core_number on the host's vm_host_cpu rows and exits" do
      other_host = create_vm_host
      VmHostCpu.import([:vm_host_id, :cpu_number, :io], [[vm_host.id, 0, true], [vm_host.id, 1, false], [vm_host.id, 2, false], [vm_host.id, 3, false], [other_host.id, 0, false]])
      nx.strand.retval = {"cpu_numa_nodes" => [0, 0, 1, 1], "cpu_cores" => [0, 1, 0, 1]}

      expect { nx.start }.to exit({"msg" => "updated numa_node and core_number for 4 cpus"})

      expect(vm_host.cpus_dataset.select_order_map([:cpu_number, :numa_node, :core_number])).to eq [[0, 0, 0], [1, 0, 1], [2, 1, 0], [3, 1, 1]]
      expect(other_host.cpus_dataset.select_order_map([:cpu_number, :numa_node, :core_number])).to eq [[0, nil, nil]]
    end

    it "leaves numa_node empty on a host without numa data" do
      VmHostCpu.import([:vm_host_id, :cpu_number, :io, :numa_node], [[vm_host.id, 0, false, 0], [vm_host.id, 1, false, 0]])
      nx.strand.retval = {"cpu_numa_nodes" => [nil, nil], "cpu_cores" => [0, 0]}

      expect { nx.start }.to exit({"msg" => "updated numa_node and core_number for 2 cpus"})

      expect(vm_host.cpus_dataset.select_order_map([:cpu_number, :numa_node, :core_number])).to eq [[0, nil, 0], [1, nil, 0]]
    end
  end
end
