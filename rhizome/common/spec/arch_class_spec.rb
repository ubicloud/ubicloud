# frozen_string_literal: true

require_relative "../lib/arch"

RSpec.describe ArchClass do
  describe "#render" do
    it "selects the user string of the matching architecture" do
      expect(described_class.new(:x64).render(x64: "test-x64", arm64: "test-arm64")).to eq("test-x64")
      expect(described_class.new(:arm64).render(x64: "test-x64", arm64: "test-arm64")).to eq("test-arm64")
    end
  end

  describe "#arm64?" do
    it "returns true for arm64" do
      expect(described_class.new(:arm64).arm64?).to be true
    end

    it "returns false for x64" do
      expect(described_class.new(:x64).arm64?).to be false
    end
  end

  describe "#x64?" do
    it "returns true for x64" do
      expect(described_class.new(:x64).x64?).to be true
    end

    it "returns false for arm64" do
      expect(described_class.new(:arm64).x64?).to be false
    end
  end

  describe ".from_system" do
    it "detects x64 from amd64 target_cpu" do
      allow(RbConfig::CONFIG).to receive(:fetch).with("target_cpu").and_return("x86_64")
      expect(described_class.from_system.sym).to eq(:x64)
    end

    it "detects x64 from x64 target_cpu" do
      allow(RbConfig::CONFIG).to receive(:fetch).with("target_cpu").and_return("x64")
      expect(described_class.from_system.sym).to eq(:x64)
    end

    it "detects arm64 from aarch64 target_cpu" do
      allow(RbConfig::CONFIG).to receive(:fetch).with("target_cpu").and_return("aarch64")
      expect(described_class.from_system.sym).to eq(:arm64)
    end

    it "detects arm64 from arm64 target_cpu" do
      allow(RbConfig::CONFIG).to receive(:fetch).with("target_cpu").and_return("arm64")
      expect(described_class.from_system.sym).to eq(:arm64)
    end

    it "raises an error for an unsupported architecture" do
      allow(RbConfig::CONFIG).to receive(:fetch).with("target_cpu").and_return("riscv64")
      expect { described_class.from_system }.to raise_error(/BUG: could not detect architecture/)
    end
  end
end
