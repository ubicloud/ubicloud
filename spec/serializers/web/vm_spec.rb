# frozen_string_literal: true

require_relative "../../spec_helper"

RSpec.describe Serializers::Web::Vm do
  let(:nic) {
    ps = PrivateSubnet.new(name: "test").tap { _1.id = "a410a91a-dc31-4119-9094-3c6a1fb49601" }
    Nic.new(
      private_ipv4: NetAddr::IPv4Net.parse("1.2.3.4/32"),
      private_ipv6: NetAddr::IPv6Net.parse("::0/0"),
      private_subnet: ps
    ).tap { _1.id = "a410a91a-dc31-4119-9094-3c6a1fb49601" }
  }
  let(:vm) { Vm.new(name: "test-vm", family: "standard", cores: 1).tap { _1.id = "a410a91a-dc31-4119-9094-3c6a1fb49601" } }
  let(:ser) { described_class.new }

  before do
    allow(vm).to receive(:nics).and_return([nic])
  end

  it "can serialize with the default structure" do
    data = ser.serialize(vm)
    expect(data[:name]).to eq(vm.name)
  end

  it "can serialize when disk not encrypted" do
    expect(vm).to receive(:storage_encrypted?).and_return(false)
    data = ser.serialize(vm)
    expect(data[:storage_encryption]).to eq("not encrypted")
  end
end
