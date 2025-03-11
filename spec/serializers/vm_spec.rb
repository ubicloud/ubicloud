# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Serializers::Vm do
  describe ".serialize_internal" do
    it "serializes a VM with no loadbalancer_vm_port correctly" do
      vm = instance_double(Vm, name: "test-vm", unix_user: "ubi", storage_size_gib: 100, ip4_enabled: true)
      expect(vm).to receive(:load_balancer_vm_ports).and_return([])
      expect(vm).to receive(:ip4_enabled).and_return(true)
      expect(vm).to receive(:display_state).and_return("running")
      expect(vm).to receive(:display_size).and_return("standard-2")
      expect(vm).to receive(:display_location).and_return("hetzner")
      expect(vm).to receive(:ubid).and_return("1234")
      expect(vm).to receive(:ephemeral_net6).and_return(nil)
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
        ip4: "192.168.1.0/24",
        load_balancer_state: nil
      }

      expect(described_class.serialize_internal(vm, {load_balancer: true})).to eq(expected_result)
    end
  end
end
