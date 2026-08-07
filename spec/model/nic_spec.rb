# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe Nic do
  let(:project) { Project.create(name: "nic-test") }
  let(:subnet) {
    PrivateSubnet.create(
      net6: "fd10:9b0b:6b4b:8fbb::/64",
      net4: "10.0.0.0/26",
      name: "nic-test-subnet",
      location_id: Location::HETZNER_FSN1_ID,
      project_id: project.id,
    )
  }

  def create_nic(subnet, name:, ipv4:, ipv6:)
    described_class.create(
      private_ipv6: ipv6,
      private_ipv4: ipv4,
      private_subnet_id: subnet.id,
      name:,
      state: "active",
    )
  end

  describe "ubid_to_name" do
    it "returns name from ubid" do
      tap = described_class.ubid_to_name("nc09797qbpze6qx7k7rmfw74rc")
      expect(tap).to eq "nc09797q"
    end
  end

  describe "ubid_to_tap_name" do
    it "returns tap name from ubid" do
      nic = described_class.create_with_id(
        UBID.parse("nc09797qbpze6qx7k7rmfw74rc").to_uuid,
        private_ipv6: "fd10:9b0b:6b4b:8fbb::/128",
        private_ipv4: "10.0.0.12/32",
        mac: "00:11:22:33:44:55",
        encryption_key: "0x30613961313636632d653765372d343434372d616232392d376561343432623562623065",
        private_subnet_id: subnet.id,
        name: "def-nic",
        state: "initializing",
      )
      expect(nic.ubid_to_tap_name).to eq "nc09797qbp"
    end
  end

  describe "private IPv4 uniqueness" do
    it "rejects the same private IPv4 in one subnet" do
      nic = create_nic(
        subnet,
        name: "first-nic",
        ipv4: "10.0.0.12/32",
        ipv6: "fd10:9b0b:6b4b:8fbb::12/128",
      )
      duplicate_values = nic.values.merge(
        id: described_class.generate_uuid,
        name: "second-nic",
        private_ipv6: "fd10:9b0b:6b4b:8fbb::13/128",
      )

      expect {
        DB.transaction(savepoint: true) do
          described_class.dataset.insert(duplicate_values)
        end
      }.to raise_error(Sequel::UniqueConstraintViolation)
    end

    it "allows the same private IPv4 in different subnets" do
      other_subnet = PrivateSubnet.create(
        net6: "fd10:9b0b:6b4b:8fbc::/64",
        net4: "10.0.0.0/26",
        name: "other-nic-test-subnet",
        location_id: Location::HETZNER_FSN1_ID,
        project_id: project.id,
      )
      first = create_nic(
        subnet,
        name: "first-nic",
        ipv4: "10.0.0.12/32",
        ipv6: "fd10:9b0b:6b4b:8fbb::12/128",
      )
      second = create_nic(
        other_subnet,
        name: "second-nic",
        ipv4: "10.0.0.12/32",
        ipv6: "fd10:9b0b:6b4b:8fbc::12/128",
      )

      expect(first.private_ipv4.to_s).to eq(second.private_ipv4.to_s)
    end

    it "allows multiple NULL private IPv4 values in one subnet" do
      first = create_nic(
        subnet,
        name: "first-nic",
        ipv4: nil,
        ipv6: "fd10:9b0b:6b4b:8fbb::12/128",
      )
      second = create_nic(
        subnet,
        name: "second-nic",
        ipv4: nil,
        ipv6: "fd10:9b0b:6b4b:8fbb::13/128",
      )

      expect([first.private_ipv4, second.private_ipv4]).to eq([nil, nil])
      expect(first.private_ipv4_address).to be_nil
    end
  end
end
