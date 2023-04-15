# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe Vm do
  subject(:vm) { described_class.new }

  describe "#mem_gib" do
    it "handles the 'standard' instance line" do
      vm.size = "standard-4"
      expect(vm.mem_gib).to eq 16
    end

    it "crashes if a bogus size is passed" do
      vm.size = "nope-10"
      expect { vm.mem_gib }.to raise_error RuntimeError, "BUG: unrecognized product line"
    end
  end

  describe "#cloud_hypervisor_cpu_topology" do
    it "scales a single-socket hyperthreaded system" do
      vm.size = "standard-2"
      expect(vm).to receive(:vm_host).and_return(instance_double(
        VmHost,
        total_cpus: 12,
        total_cores: 6,
        total_nodes: 1,
        total_sockets: 1
      )).at_least(:once)
      expect(vm.cloud_hypervisor_cpu_topology.to_s).to eq("2:2:1:1")
    end

    it "scales a dual-socket hyperthreaded system" do
      vm.size = "standard-2"
      expect(vm).to receive(:vm_host).and_return(instance_double(
        VmHost,
        total_cpus: 24,
        total_cores: 12,
        total_nodes: 2,
        total_sockets: 2
      )).at_least(:once)
      expect(vm.cloud_hypervisor_cpu_topology.to_s).to eq("2:2:1:1")
    end

    context "with a dual socket Ampere Altra" do
      before do
        expect(vm).to receive(:vm_host).and_return(instance_double(
          # Based on a dual-socket Ampere Altra running in quad-node
          # per chip mode.
          VmHost,
          total_cpus: 160,
          total_cores: 160,
          total_nodes: 8,
          total_sockets: 2
        )).at_least(:once)
      end

      it "prefers involving fewer sockets and numa nodes" do
        # Altra chips are 20 cores * 4 numa nodes, in the finest
        # grained configuration, such an allocation we prefer to grant
        # locality so the VM guest doesn't have to think about NUMA
        # until this size.
        vm.size = "standard-20"
        expect(vm.cloud_hypervisor_cpu_topology.to_s).to eq("1:20:1:1")
      end

      it "can compute bizarre, multi-node topologies for bizarre allocations" do
        vm.size = "standard-90"
        expect(vm.cloud_hypervisor_cpu_topology.to_s).to eq("1:15:3:2")
      end
    end
  end
end
