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
    expect(described_class).to receive(:write).with({vm: {id: "123"}, message: "model", time: now})
    described_class.emit("model", Vm.new(public_key: "redacted_key").tap { it.id = "123" })
  end

  it "returns a combined hash when the metadata is an array" do
    expect(described_class).to receive(:write).with({vm: {id: "123"}, field1: "custom", invalid_type: "String", message: "model", time: now})
    vm = Vm.new(public_key: "redacted_key").tap { it.id = "123" }
    described_class.emit("model", [vm, {field1: "custom"}, "invalid"])
  end
end
