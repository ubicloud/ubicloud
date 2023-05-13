# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe VmHost do
  subject(:vh) {
    described_class.new(
      net6: NetAddr.parse_net("2a01:4f9:2b:35a::/64"),
      ip6: NetAddr.parse_ip("2a01:4f9:2b:35a::2")
    )
  }

  it "requires an Sshable too" do
    expect {
      sa = Sshable.create(host: "test.localhost", raw_private_key_1: SshKey.generate.keypair)
      described_class.create(location: "test-location") { _1.id = sa.id }
    }.not_to raise_error
  end

  it "can generate random ipv6 subnets" do
    expect(vh.ip6_random_vm_network.contains(vh.ip6)).to be false
  end

  it "crashes if the prefix length for a VM is shorter than the host's prefix" do
    expect {
      vh.ip6_reserved_network(1)
    }.to raise_error RuntimeError, "BUG: host prefix must be is shorter than reserved prefix"
  end

  it "tries to get another random network if the proposal matches the reserved nework" do
    expect(SecureRandom).to receive(:bytes).and_return("\0\0")
    expect(SecureRandom).to receive(:bytes).and_call_original
    expect(vh.ip6_random_vm_network.to_s).not_to eq(vh.ip6_reserved_network)
  end

  it "has a shortcut to install Rhizome" do
    vh.id = "46683a25-acb1-4371-afe9-d39f303e44b4"
    expect(Strand).to receive(:create) do |args|
      expect(args[:prog]).to eq("InstallRhizome")
      expect(args[:stack]).to eq([subject_id: vh.id])
    end
    vh.install_rhizome
  end
end
