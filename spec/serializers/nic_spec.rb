# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Serializers::Nic do
  describe ".serialize_internal" do
    it "serializes a NIC with a non-/32 IPv4 subnet correctly" do
      vm = instance_double(Vm, name: "test-vm")

      private_ipv4 = NetAddr::IPv4Net.parse("192.168.1.0/24")
      private_ipv6 = NetAddr::IPv6Net.parse("fd91:4ef3:a586:943d:c2ae::/79")

      nic = Nic.new_with_id(name: "nic-name", private_ipv4: private_ipv4, private_ipv6: private_ipv6)
      nic.associations[:vm] = vm

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
      vm = instance_double(Vm, name: "test-vm")

      private_ipv4 = NetAddr::IPv4Net.parse("10.23.34.53/32")
      private_ipv6 = NetAddr::IPv6Net.parse("fd91:4ef3:a586:943d:c2ae::/79")

      nic = Nic.new_with_id(name: "nic-name", private_ipv4: private_ipv4, private_ipv6: private_ipv6)
      nic.associations[:vm] = vm

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
