# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Serializers::Vm do
  let(:vm) {
    project = Project.create(name: "test-project")
    vm_host = create_vm_host(location_id: Location::HETZNER_FSN1_ID)
    vm = Prog::Vm::Nexus.assemble("dummy-public key", project.id, name: "test-vm", location_id: Location::HETZNER_FSN1_ID, enable_ip4: true).subject
    vm.update(display_state: "running", vm_host_id: vm_host.id)
    vm.vm_storage_volumes.first.update(size_gib: 100)
    add_ipv4_to_vm(vm, "192.168.1.0")
    vm
  }

  def prepare_for_comparison(serialized)
    [:ip4, :ip6, :private_ipv4, :private_ipv6].each do |ip_field|
      serialized[ip_field] = serialized[ip_field].to_s if serialized[ip_field]
    end
    serialized
  end

  describe ".serialize_internal" do
    it "serializes a VM with no loadbalancer_vm_port correctly" do
      expected_result = {
        id: vm.ubid,
        name: "test-vm",
        state: "running",
        location: "eu-central-h1",
        size: "standard-2",
        unix_user: "ubi",
        storage_size_gib: 100,
        ip6: nil,
        ip4_enabled: true,
        ip4: "192.168.1.0",
      }

      expect(prepare_for_comparison(described_class.serialize_internal(vm))).to eq(expected_result)
    end

    it "serializes a VM with GPU correctly" do
      PciDevice.create(vm_host_id: vm.vm_host_id, vm_id: vm.id, slot: "00:00.0", device_class: "0300", vendor: "nvidia", device: "20b5", numa_node: 0, iommu_group: 0)

      expected_result = {
        id: vm.ubid,
        name: "test-vm",
        state: "running",
        location: "eu-central-h1",
        size: "standard-2",
        unix_user: "ubi",
        storage_size_gib: 100,
        ip6: nil,
        ip4_enabled: true,
        ip4: "192.168.1.0",
        firewalls: Serializers::Firewall.serialize(vm.firewalls, {include_path: true}),
        private_ipv4: vm.private_ipv4.to_s,
        private_ipv6: vm.private_ipv6.to_s,
        subnet: "default-eu-central-h1",
        gpu: "1x NVIDIA A100 80GB PCIe",
      }

      expect(prepare_for_comparison(described_class.serialize_internal(vm, {detailed: true}))).to eq(expected_result)
    end
  end
end
