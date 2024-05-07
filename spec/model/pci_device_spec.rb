# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe PciDevice do
  it "returns correctly that a device with class 300 is a gpu" do
    d = described_class.new(device_class: "0300")
    expect(d.is_gpu).to be_truthy
  end

  it "returns correctly that a device with class 302 is a gpu" do
    d = described_class.new(device_class: "0302")
    expect(d.is_gpu).to be_truthy
  end

  it "returns correctly that a device is not a gpu" do
    d = described_class.new(device_class: "0403")
    expect(d.is_gpu).to be_falsy
  end
end
