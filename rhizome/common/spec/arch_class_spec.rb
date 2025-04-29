# frozen_string_literal: true

require_relative "../lib/arch"

RSpec.describe ArchClass do
  describe "#render" do
    it "selects the user string of the matching architecture" do
      expect(described_class.new(:x64).render(x64: "test-x64", arm64: "test-arm64")).to eq("test-x64")
      expect(described_class.new(:arm64).render(x64: "test-x64", arm64: "test-arm64")).to eq("test-arm64")
    end
  end
end
