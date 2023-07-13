# frozen_string_literal: true

require_relative "../../spec_helper"

RSpec.describe Serializers::Web::Vm do
  let(:vm) { Vm.new(name: "test-vm", size: "m5a.2x").tap { _1.id = "a410a91a-dc31-4119-9094-3c6a1fb49601" } }
  let(:ser) { described_class.new(:default) }

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
