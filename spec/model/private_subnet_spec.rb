# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe PrivateSubnet do
  subject(:private_subnet) {
    described_class.new(
      net6: NetAddr.parse_net("fd1b:9793:dcef:cd0a::/64"),
      net4: NetAddr.parse_net("10.9.39.0/26"),
      location: "hetzner-hel1",
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
      expect(SecureRandom).to receive(:random_number).with(59).and_return(5)
      expect(private_subnet.random_private_ipv4.to_s).to eq "10.9.39.9/32"
    end

    it "returns random private ipv6" do
      expect(SecureRandom).to receive(:random_number).with(32766).and_return(5)
      expect(private_subnet.random_private_ipv6.to_s).to eq "fd1b:9793:dcef:cd0a:c::/79"
    end

    it "returns random private ipv4 when ip exists" do
      expect(SecureRandom).to receive(:random_number).with(59).and_return(1, 2)
      expect(private_subnet).to receive(:nics).and_return([existing_nic]).twice
      expect(private_subnet.random_private_ipv4.to_s).to eq "10.9.39.6/32"
    end

    it "returns random private ipv6 when ip exists" do
      expect(SecureRandom).to receive(:random_number).with(32766).and_return(5, 6)
      expect(private_subnet).to receive(:nics).and_return([existing_nic]).twice
      expect(private_subnet.random_private_ipv6.to_s).to eq "fd1b:9793:dcef:cd0a:e::/79"
    end
  end

  describe "uuid to name" do
    it "returns the name" do
      expect(described_class.ubid_to_name("psetv2ff83xj6h3prt2jwavh0q")).to eq "psetv2ff"
    end
  end

  describe "ui utility methods" do
    it "returns path" do
      expect(private_subnet.path).to eq "/location/eu-north-h1/private-subnet/ps"
    end

    it "returns tag name" do
      pr = instance_double(Project, ubid: "prjubid")
      expect(private_subnet.hyper_tag_name(pr)).to eq "project/prjubid/location/eu-north-h1/private-subnet/ps"
    end
  end

  describe "display_state" do
    it "returns available when waiting" do
      expect(private_subnet.display_state).to eq "available"
    end

    it "returns state if not waiting" do
      private_subnet.state = "failed"
      expect(private_subnet.display_state).to eq "failed"
    end
  end

  describe "destroy" do
    it "destroys firewalls private subnets" do
      ps = described_class.create_with_id(name: "test-ps", location: "hetzner-hel1", net6: "2001:db8::/64", net4: "10.0.0.0/24")
      fwps = instance_double(FirewallsPrivateSubnets)
      expect(FirewallsPrivateSubnets).to receive(:where).with(private_subnet_id: ps.id).and_return(instance_double(Sequel::Dataset, all: [fwps]))
      expect(fwps).to receive(:destroy).once
      ps.destroy
    end
  end
end
