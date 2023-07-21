# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe PrivateSubnet do
  subject(:private_subnet) {
    described_class.new(
      net6: NetAddr.parse_net("fd1b:9793:dcef:cd0a::/64"),
      net4: NetAddr.parse_net("10.9.39.0/26"),
      location: "hel1",
      state: "waiting",
      name: "ps"
    )
  }

  let(:nic) { instance_double(Nic, id: "0a9a166c-e7e7-4447-ab29-7ea442b5bb0e") }
  let(:existing_nic) {
    instance_double(Nic,
      id: "46ca6ded-b056-4723-bd91-612959f52f6f",
      private_ipv4: "10.9.39.5/32",
      private_ipv6: "fd1b:9793:dcef:cd0a:c::/79")
  }

  describe "random ip generation" do
    it "returns random private ipv4" do
      expect(SecureRandom).to receive(:random_number).with(63).and_return(5)
      expect(private_subnet.random_private_ipv4.to_s).to eq "10.9.39.5/32"
    end

    it "returns random private ipv6" do
      expect(SecureRandom).to receive(:random_number).with(32767).and_return(5)
      expect(private_subnet.random_private_ipv6.to_s).to eq "fd1b:9793:dcef:cd0a:c::/79"
    end

    it "returns random private ipv4 when ip exists" do
      expect(SecureRandom).to receive(:random_number).with(63).and_return(5, 6)
      expect(private_subnet).to receive(:nics).and_return([existing_nic]).twice
      expect(private_subnet.random_private_ipv4.to_s).to eq "10.9.39.6/32"
    end

    it "returns random private ipv6 when ip exists" do
      expect(SecureRandom).to receive(:random_number).with(32767).and_return(5, 6)
      expect(private_subnet).to receive(:nics).and_return([existing_nic]).twice
      expect(private_subnet.random_private_ipv6.to_s).to eq "fd1b:9793:dcef:cd0a:e::/79"
    end
  end

  describe "add nic" do
    it "skips a nic if it exists" do
      expect(private_subnet).to receive(:nics).and_return([nic])
      expect(IpsecTunnel).not_to receive(:create)
      private_subnet.add_nic(nic)
    end

    it "adds IpsecTunnel when a nic is added" do
      expect(private_subnet).to receive(:nics).and_return([existing_nic])
      expect(IpsecTunnel).to receive(:create).with(src_nic_id: existing_nic.id, dst_nic_id: nic.id)
      expect(IpsecTunnel).to receive(:create).with(src_nic_id: nic.id, dst_nic_id: existing_nic.id)
      private_subnet.add_nic(nic)
    end
  end

  describe "uuid to name" do
    it "returns the name" do
      expect(described_class.ubid_to_name("psetv2ff83xj6h3prt2jwavh0q")).to eq "psetv2ff"
    end
  end
end
