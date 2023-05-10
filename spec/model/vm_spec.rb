# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe Vm do
  subject(:vm) { described_class.new }

  describe "#product" do
    it "crashes if a bogus product is passed" do
      vm.size = "bogustext"
      expect { vm.product }.to raise_error RuntimeError, "BUG: cannot parse vm size"
    end
  end

  describe "#mem_gib" do
    it "handles the 'm5a' instance line" do
      vm.size = "m5a.2x"
      expect(vm.mem_gib).to eq 4
    end

    it "handles the 'c5a' instance line" do
      vm.size = "c5a.2x"
      expect(vm.mem_gib).to eq 2
    end

    it "crashes if a bogus size is passed" do
      vm.size = "nope.10x"
      expect { vm.mem_gib }.to raise_error RuntimeError, "BUG: unrecognized product line"
    end
  end

  describe "#cloud_hypervisor_cpu_topology" do
    it "scales a single-socket hyperthreaded system" do
      vm.size = "m5a.4x"
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
      vm.size = "m5a.4x"
      expect(vm).to receive(:vm_host).and_return(instance_double(
        VmHost,
        total_cpus: 24,
        total_cores: 12,
        total_nodes: 2,
        total_sockets: 2
      )).at_least(:once)
      expect(vm.cloud_hypervisor_cpu_topology.to_s).to eq("2:2:1:1")
    end

    it "crashes if total_cpus is not multiply of total_cores" do
      expect(vm).to receive(:vm_host).and_return(instance_double(
        VmHost,
        total_cpus: 3,
        total_cores: 2
      )).at_least(:once)

      expect { vm.cloud_hypervisor_cpu_topology }.to raise_error RuntimeError, "BUG"
    end

    it "crashes if total_nodes is not multiply of total_sockets" do
      expect(vm).to receive(:vm_host).and_return(instance_double(
        VmHost,
        total_cpus: 24,
        total_cores: 12,
        total_nodes: 3,
        total_sockets: 2
      )).at_least(:once)

      expect { vm.cloud_hypervisor_cpu_topology }.to raise_error RuntimeError, "BUG"
    end

    it "crashes if cores allocated per die is not uniform number" do
      vm.size = "m5a.4x"

      expect(vm).to receive(:vm_host).and_return(instance_double(
        VmHost,
        total_cpus: 1,
        total_cores: 1,
        total_nodes: 1,
        total_sockets: 1
      )).at_least(:once)

      expect { vm.cloud_hypervisor_cpu_topology }.to raise_error RuntimeError, "BUG: need uniform number of cores allocated per die"
    end

    context "with a dual socket Ampere Altra" do
      # YYY: Hacked up to pretend Ampere Altras have hyperthreading
      # for demonstration on small metal instances.

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
        vm.size = "m5a.40x"
        expect(vm.cloud_hypervisor_cpu_topology.to_s).to eq("1:20:1:1")
      end

      it "can compute bizarre, multi-node topologies for bizarre allocations" do
        vm.size = "m5a.180x"
        expect(vm.cloud_hypervisor_cpu_topology.to_s).to eq("1:15:3:2")
      end
    end
  end
end
