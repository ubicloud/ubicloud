# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe Vm do
  subject(:vm) { described_class.new(display_state: "creating") }

  describe "#display_state" do
    it "returns deleting if destroy semaphore increased" do
      expect(vm).to receive(:semaphores).and_return([instance_double(Semaphore, name: "destroy")])
      expect(vm.display_state).to eq("deleting")
    end

    it "return same if semaphores not increased" do
      expect(vm.display_state).to eq("creating")
    end
  end

  describe "#mem_gib" do
    it "handles standard-2" do
      vm.family = "standard"
      vm.cores = 1
      expect(vm.mem_gib).to eq 8
    end

    it "handles standard-16" do
      vm.family = "standard"
      vm.cores = 8
      expect(vm.mem_gib).to eq 64
    end
  end

  describe "#cloud_hypervisor_cpu_topology" do
    it "scales a single-socket hyperthreaded system" do
      vm.family = "standard"
      vm.cores = 2
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
      vm.family = "standard"
      vm.cores = 2
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
      vm.family = "standard"
      vm.cores = 2

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
        expect(vm).to receive(:cores).and_return(20).at_least(:once)
        expect(vm.cloud_hypervisor_cpu_topology.to_s).to eq("1:20:1:1")
      end

      it "can compute multi-node topologies for stranger allocations" do
        expect(vm).to receive(:cores).and_return(90).at_least(:once)
        expect(vm.cloud_hypervisor_cpu_topology.to_s).to eq("1:15:3:2")
      end
    end
  end

  describe "#utility functions" do
    it "can compute the ipv4 addresses" do
      as_ad = instance_double(AssignedVmAddress, ip: NetAddr::IPv4Net.new(NetAddr.parse_ip("1.1.1.0"), NetAddr::Mask32.new(32)))
      expect(vm).to receive(:assigned_vm_address).and_return(as_ad).at_least(:once)
      expect(vm.ephemeral_net4.to_s).to eq("1.1.1.0")
      expect(vm.ip4.to_s).to eq("1.1.1.0/32")
    end

    it "can compute nil if ipv4 is not assigned" do
      expect(vm.ephemeral_net4).to be_nil
    end
  end
end
