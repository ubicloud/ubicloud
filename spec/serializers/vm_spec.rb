# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Serializers::Vm do
  describe ".serialize_internal" do
    it "serializes a VM with no loadbalancer_vm_port correctly" do
      vm = instance_double(Vm, name: "test-vm", unix_user: "ubi", storage_size_gib: 100, ip4_enabled: true)
      expect(vm).to receive(:ip4_enabled).and_return(true)
      expect(vm).to receive(:display_state).and_return("running")
      expect(vm).to receive(:display_size).and_return("standard-2")
      expect(vm).to receive(:display_location).and_return("hetzner")
      expect(vm).to receive(:ubid).and_return("1234")
      expect(vm).to receive(:ip6).and_return(nil)
      expect(vm).to receive(:ephemeral_net4).and_return("192.168.1.0/24")

      expected_result = {
        id: "1234",
        name: "test-vm",
        state: "running",
        location: "hetzner",
        size: "standard-2",
        unix_user: "ubi",
        storage_size_gib: 100,
        ip6: nil,
        ip4_enabled: true,
        ip4: "192.168.1.0/24"
      }

      expect(described_class.serialize_internal(vm)).to eq(expected_result)
    end

    it "serializes a VM with GPU correctly" do
      vm = instance_double(Vm, name: "test-vm", unix_user: "ubi", storage_size_gib: 100, ip4_enabled: true)
      expect(vm).to receive(:ip4_enabled).and_return(true)
      expect(vm).to receive(:display_state).and_return("running")
      expect(vm).to receive(:display_size).and_return("standard-2")
      expect(vm).to receive(:display_location).and_return("hetzner")
      expect(vm).to receive(:ubid).and_return("1234")
      expect(vm).to receive(:ip6).and_return(nil)
      expect(vm).to receive(:ephemeral_net4).and_return("192.168.1.0/24")
      expect(vm).to receive(:display_gpu).and_return("1x NVIDIA A100 80GB PCIe")
      expect(vm).to receive(:firewalls).and_return([])
      expect(vm).to receive(:private_ipv4).and_return("10.0.0.1")
      expect(vm).to receive(:private_ipv6).and_return("fd00::1")
      expect(vm).to receive(:nics).and_return([instance_double(Nic, private_subnet: instance_double(PrivateSubnet, name: "subnet-1"))])

      expected_result = {
        id: "1234",
        name: "test-vm",
        state: "running",
        location: "hetzner",
        size: "standard-2",
        unix_user: "ubi",
        storage_size_gib: 100,
        ip6: nil,
        ip4_enabled: true,
        ip4: "192.168.1.0/24",
        firewalls: [],
        private_ipv4: "10.0.0.1",
        private_ipv6: "fd00::1",
        subnet: "subnet-1",
        gpu: "1x NVIDIA A100 80GB PCIe"
      }

      expect(described_class.serialize_internal(vm, {detailed: true})).to eq(expected_result)
    end
  end
end
