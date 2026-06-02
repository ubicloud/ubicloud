# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Serializers::Vm do
  let(:project) { Project.create(name: "test-project") }
  let(:vm) do
    vm = Prog::Vm::Nexus.assemble("dummy-public key", project.id, name: "test-vm").subject
    vm.update(display_state: "running")
    vm
  end

  describe ".serialize_internal" do
    it "serializes a VM without detailed fields" do
      add_ipv4_to_vm(vm, "192.168.1.0")

      result = described_class.serialize_internal(vm.reload)
      expect(result.except(:ip4)).to eq(
        id: vm.ubid,
        name: "test-vm",
        state: "running",
        location: "eu-central-h1",
        size: "standard-2",
        unix_user: "ubi",
        storage_size_gib: vm.storage_size_gib,
        ip6: nil,
        ip4_enabled: false,
      )
      expect(result[:ip4].to_s).to eq("192.168.1.0")
    end

    it "serializes a VM with detailed fields and a GPU" do
      add_ipv4_to_vm(vm, "192.168.1.0")
      PciDevice.create(vm_host_id: create_vm_host.id, vm_id: vm.id, slot: "00:00.0", device_class: "0300", vendor: "nvidia", device: "2901", numa_node: 0, iommu_group: 0)

      result = described_class.serialize_internal(vm.reload, {detailed: true})
      expect(result.slice(:id, :name, :state, :location, :size, :unix_user, :storage_size_gib, :ip6, :ip4_enabled, :subnet, :gpu)).to eq(
        id: vm.ubid,
        name: "test-vm",
        state: "running",
        location: "eu-central-h1",
        size: "standard-2",
        unix_user: "ubi",
        storage_size_gib: vm.storage_size_gib,
        ip6: nil,
        ip4_enabled: false,
        subnet: vm.nics.first.private_subnet.name,
        gpu: "1x #{PciDevice.device_name("2901")}",
      )
      expect(result[:ip4].to_s).to eq("192.168.1.0")
      expect(result[:private_ipv4].to_s).to eq(vm.private_ipv4.to_s)
      expect(result[:private_ipv6].to_s).to eq(vm.private_ipv6.to_s)
      expect(result[:firewalls].length).to eq(1)
      expect(result[:firewalls].first).to include(name: vm.firewalls.first.name)
    end
  end
end
