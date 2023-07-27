# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Serializers::Base do
  it "use default structure when not provided" do
    ser = described_class.new
    expect(ser.instance_variable_get(:@type)).to eq(:default)
  end

  it "initilize new seriliazer when class method called" do
    ser = instance_double(described_class)
    expect(described_class).to receive(:new).and_return(ser)
    expect(ser).to receive(:serialize).and_return({})

    expect(described_class.serialize(nil)).to eq({})
  end
end
