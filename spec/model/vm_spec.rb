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

  describe Vm::Product do
    it "can render and parse products" do
      products = [
        ["amd", 20, 0.3, 4],
        ["amd", 20, 1, 4],
        ["amd", 20, 2, 8],
        ["amd", 20, 4, 16],
        ["amd", 20, 8, 32],
        ["amd", 20, 64, 512],
        ["amd", 30, 1024, 16384]
      ].map {
        described_class.new(**[:manufacturer, :year, :cores, :ram].zip(_1).to_h)
      }
      strings = products.map(&:to_s)
      expect(strings).to eq(%w[
        amd20-0.3c-4r
        amd20-1c-4r
        amd20-2c-8r
        amd20-4c-t16r
        amd20-8c-t32r
        amd20-t64c-u512r
        amd30-v1024c-w16384r
      ])
      expect(strings.map { described_class.parse(_1) }).to eq(products)
    end

    it "rejects input that cannot have a sort assist byte inserted" do
      expect {
        described_class.parse("amd20-4c-666666r")
      }.to raise_error RuntimeError, "BUG: unsupported number of digits"
    end
  end

  describe "#cloud_hypervisor_cpu_topology" do
    it "scales a single-socket hyperthreaded system" do
      vm.size = "amd19-2c-4r"
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
      vm.size = "amd19-2c-4r"
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
      vm.size = "amd19-2c-4r"

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
        vm.size = "ampere20-t20c-t64r"
        expect(vm.cloud_hypervisor_cpu_topology.to_s).to eq("1:20:1:1")
      end

      it "can compute bizarre, multi-node topologies for bizarre allocations" do
        vm.size = "ampere20-t90c-t256r"
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
