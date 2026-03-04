# frozen_string_literal: true

RSpec.describe Clog do
  let(:now) { Time.parse("2023-01-17 12:10:54 -0800") }

  before do
    allow(Time).to receive(:now).and_return(now)
  end

  it "writes to $stdout in non-test mode" do
    allow(Config).to receive(:test?).and_return(false)
    expect($stdout).to receive(:write).with('{"message":"hello","time":"' + now.to_s + '"}' + "\n")
    described_class.emit "hello"
  end

  it "adds the thread name to the structured data" do
    Thread.new do
      Thread.current.name = "test thread name"
      expect(described_class).to receive(:write).with({message: "hello", time: now, thread: "test thread name"})
      described_class.emit "hello"
    end.join
  end

  it "writes an error when an invalid type is yield from the block" do
    expect(described_class).to receive(:write).with({invalid_type: "Integer", message: "ngmi", time: now})
    described_class.emit("ngmi", 1)
  end

  it "returns the key with redacted values for Sequel::Model" do
    vm = Vm.new_with_id(public_key: "redacted_key", name: "A")
    expect(described_class).to receive(:write).with({vm: {id: vm.ubid, name: "A"}, message: "model", time: now})
    described_class.emit("model", vm)
  end

  it "returns a combined hash when the metadata is an array" do
    vm = Vm.new_with_id(public_key: "redacted_key", name: "A")
    expect(described_class).to receive(:write).with({vm: {id: vm.ubid, name: "A"}, field1: "custom", invalid_type: "String", message: "model", time: now})
    described_class.emit("model", [vm, {field1: "custom"}, "invalid"])
  end
end
