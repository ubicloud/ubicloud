# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Serializers::Base do
  it "raises an error when serialize_internal is called" do
    expect { described_class.serialize_internal(nil) }.to raise_error(NoMethodError)
  end

  it "returns nil if nil is passed" do
    expect(described_class.serialize(nil)).to be_nil
  end
end
