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

  it "returns correct names" do
    expect(described_class.new(device_class: "0302", vendor: "10de", device: "20b5").name).to equal("NVIDIA A100 80GB PCIe")
    expect(described_class.new(device_class: "0300", vendor: "10de", device: "27b0").name).to equal("NVIDIA RTX 4000 SFF Ada Generation")
    expect(described_class.new(device_class: "0302", vendor: "10de", device: "2901").name).to equal("NVIDIA B200")
    expect(described_class.new(device_class: "0302", vendor: "10de", device: "????").name).to equal("PCI device")
  end
end
