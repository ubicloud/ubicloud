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
        state: "initializing"
      )
      expect(nic).to receive(:ubid).and_return("nc09797qbpze6qx7k7rmfw74rc")
      expect(nic.ubid_to_tap_name).to eq "nc09797qbp"
    end
  end

  describe ".unlock" do
    it "destroys all semaphores with name lock" do
      prj = Project.create(name: "prj")
      ps = Prog::Vnet::SubnetNexus.assemble(prj.id, name: "ps").subject
      nic = Prog::Vnet::NicNexus.assemble(ps.id, name: "nic").subject
      nic.incr_lock

      expect(nic.lock_set?).to be true

      expect { nic.unlock }.to change { Semaphore.where(strand_id: nic.strand.id, name: "lock").count }.by(-1)
      expect(nic.reload.lock_set?).to be false
    end
  end
end
