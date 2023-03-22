# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe VmHost do
  it "requires an Sshable too" do
    expect {
      sa = Sshable.create(host: "test.localhost", private_key: "test not a real private key")
      described_class.create(location: "test-location") { _1.id = sa.id }
    }.not_to raise_error
  end

  it "can generate random ipv6 subnets" do
    vh = described_class.new(
      net6: NetAddr.parse_net("2a01:4f9:2b:35a::/64"),
      ip6: NetAddr.parse_ip("2a01:4f9:2b:35a::2")
    )
    expect(vh.ip6_random_vm_network.contains(vh.ip6)).to be false
  end
end
