# frozen_string_literal: true

require_relative "../model/spec_helper"

RSpec.describe Prog::LearnNumaNode do
  subject(:nx) { described_class.new(Strand.new(stack: [{"subject_id" => vm_host.id}])) }

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
      expect(st.prog).to eq "LearnNumaNode"
      expect(st.label).to eq "start"
      expect(described_class.new(st).vm_host.id).to eq vm_host.id
    end
  end

  describe "#start" do
    it "pushes LearnCpu when there is no retval yet" do
      expect { nx.start }.to hop("start", "LearnCpu")
    end

    it "fails if the VmHost has no vm_host_cpu rows" do
      nx.strand.retval = {"cpu_numa_nodes" => [0, 0, 1, 1]}
      expect { nx.start }.to raise_error RuntimeError, "VmHost has no vm_host_cpu rows to update"
    end

    it "fails if lscpu reports a different cpu count than vm_host_cpu has rows for" do
      VmHostCpu.create(vm_host_id: vm_host.id, cpu_number: 0, spdk: false)
      nx.strand.retval = {"cpu_numa_nodes" => [0, 0, 1, 1]}
      expect {
        nx.start
      }.to raise_error RuntimeError, "lscpu reported 4 cpus, but VmHost has 1 vm_host_cpu rows"
    end

    it "updates numa_node on the existing vm_host_cpu rows and exits" do
      4.times { |cpu_number| VmHostCpu.create(vm_host_id: vm_host.id, cpu_number:, spdk: false) }
      nx.strand.retval = {"cpu_numa_nodes" => [0, 0, 1, 1]}

      expect { nx.start }.to exit({"msg" => "updated numa_node for 4 cpus"})

      expect(VmHostCpu.where(vm_host_id: vm_host.id).select_order_map([:cpu_number, :numa_node])).to eq(
        [[0, 0], [1, 0], [2, 1], [3, 1]],
      )
    end
  end
end
