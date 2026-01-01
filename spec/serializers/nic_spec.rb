# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Serializers::Nic do
  describe ".serialize_internal" do
    let(:vm) { create_vm(name: "test-vm") }
    let(:private_subnet) { PrivateSubnet.create(name: "test-ps", location_id: Location::HETZNER_FSN1_ID, net6: "fd91:4ef3:a586:943d::/64", net4: "192.168.1.0/24", project_id: vm.project_id) }

    it "serializes a NIC with a non-/32 IPv4 subnet correctly" do
      nic = Nic.create(
        name: "nic-name",
        vm_id: vm.id,
        private_subnet_id: private_subnet.id,
        private_ipv4: "192.168.1.0/24",
        private_ipv6: "fd91:4ef3:a586:943d:c2ae::/79",
        mac: "00:00:00:00:00:01",
        state: "active"
      )

      expected_result = {
        id: nic.ubid,
        name: "nic-name",
        private_ipv4: "192.168.1.1",
        private_ipv6: "fd91:4ef3:a586:943d:c2ae::2",
        vm_name: "test-vm"
      }

      expect(described_class.serialize_internal(nic)).to eq(expected_result)
    end

    it "serializes a NIC object correctly" do
      nic = Nic.create(
        name: "nic-name",
        vm_id: vm.id,
        private_subnet_id: private_subnet.id,
        private_ipv4: "10.23.34.53/32",
        private_ipv6: "fd91:4ef3:a586:943d:c2ae::/79",
        mac: "00:00:00:00:00:02",
        state: "active"
      )

      expected_result = {
        id: nic.ubid,
        name: "nic-name",
        private_ipv4: "10.23.34.53",
        private_ipv6: "fd91:4ef3:a586:943d:c2ae::2",
        vm_name: "test-vm"
      }

      expect(described_class.serialize_internal(nic)).to eq(expected_result)
    end
  end
end
