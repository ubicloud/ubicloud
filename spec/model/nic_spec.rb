# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe Nic do
  describe "ubid_to_name" do
    it "returns name from ubid" do
      tap = described_class.ubid_to_name("nc09797qbpze6qx7k7rmfw74rc")
      expect(tap).to eq "nc09797q"
    end
  end

  describe "ubid_to_tap_name" do
    let(:subnet) { PrivateSubnet.create(net6: "0::0", net4: "127.0.0.1", name: "x", location_id: Location::HETZNER_FSN1_ID, project_id: Project.create(name: "test").id) }

    it "returns tap name from ubid" do
      nic = described_class.create(
        private_ipv6: "fd10:9b0b:6b4b:8fbb::/128",
        private_ipv4: "10.0.0.12/32",
        mac: "00:11:22:33:44:55",
        encryption_key: "0x30613961313636632d653765372d343434372d616232392d376561343432623562623065",
        private_subnet_id: subnet.id,
        name: "def-nic",
        state: "initializing",
      )
      expect(nic).to receive(:ubid).and_return("nc09797qbpze6qx7k7rmfw74rc")
      expect(nic.ubid_to_tap_name).to eq "nc09797qbp"
    end
  end

  describe "private_ipv4_address" do
    it "returns nil while AWS is assigning the address" do
      subnet = PrivateSubnet.create(
        net6: "fd10:9b0b:6b4b:8fbb::/64",
        net4: "10.0.0.0/16",
        name: "pending-ipv4",
        location_id: Location::HETZNER_FSN1_ID,
        project_id: Project.create(name: "pending-ipv4").id,
      )
      nic = described_class.create(
        private_ipv6: "fd10:9b0b:6b4b:8fbb::/128",
        private_ipv4: nil,
        private_subnet_id: subnet.id,
        name: "pending-ipv4",
        state: "creating",
      )

      expect(nic.private_ipv4_address).to be_nil
    end

    it "rejects a missing address after provisioning" do
      subnet = PrivateSubnet.create(
        net6: "fd10:9b0b:6b4b:8fbb::/64",
        net4: "10.0.0.0/16",
        name: "missing-active-ipv4",
        location_id: Location::HETZNER_FSN1_ID,
        project_id: Project.create(name: "missing-active-ipv4").id,
      )

      expect {
        described_class.dataset.insert(
          id: described_class.generate_uuid,
          private_ipv6: "fd10:9b0b:6b4b:8fbb::/128",
          private_ipv4: nil,
          private_subnet_id: subnet.id,
          name: "missing-active-ipv4",
          state: "active",
        )
      }.to raise_error(Sequel::CheckConstraintViolation, /nic_private_ipv4_presence_check/)
    end
  end
end
