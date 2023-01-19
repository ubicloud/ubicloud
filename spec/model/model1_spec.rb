# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe Model1 do
  it "can instantiate" do
    obj = described_class.new
    expect(obj.id).to be_nil
    # ...
  end
end
