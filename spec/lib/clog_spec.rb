# frozen_string_literal: true

RSpec.describe Clog do
  before do
    allow(Config).to receive(:test?).and_return(false)
  end

  it "will add the thread name to the structure data, if defined" do
    Thread.new do
      Thread.current.name = "test thread name"
      expect($stdout).to receive(:write).with('{"message":"hello","thread":"test thread name"}' + "\n")
      described_class.emit "hello"
    end.join
  end

  it "doesn't include a thread name if it is not set" do
    expect($stdout).to receive(:write).with('{"message":"hello"}' + "\n")
    described_class.emit "hello"
  end

  it "writes an error when an invalid type is yield from the block" do
    expect($stdout).to receive(:write).with('{"invalid_type":"Integer","message":"ngmi"}' + "\n")
    described_class.emit("ngmi") { 1 }
  end
end
