# frozen_string_literal: true

RSpec.describe Validation do
  describe "#validate_name" do
    it "valid names" do
      [
        "abc",
        "abc123",
        "abc-123",
        "123abc",
        "abc--123",
        "a-b-c-1-2",
        "a" * 63
      ].each do |name|
        expect(described_class.validate_name(name)).to be_nil
      end
    end

    it "invalid names" do
      [
        "-abc",
        "abc-",
        "-abc-",
        "ABC",
        "ABC_123",
        "ABC$123",
        "a" * 64
      ].each do |name|
        expect { described_class.validate_name(name) }.to raise_error described_class::ValidationFailed
      end
    end

    describe "#validate_provider" do
      it "valid provider" do
        expect(described_class.validate_provider("hetzner")).to be_nil
      end

      it "invalid provider" do
        expect { described_class.validate_provider("hetzner-cloud") }.to raise_error described_class::ValidationFailed
      end
    end

    describe "#validate_location" do
      it "valid locations" do
        [
          ["hetzner-hel1", nil],
          ["hetzner-hel1", "hetzner"]
        ].each do |location, provider|
          expect(described_class.validate_location(location, provider)).to be_nil
        end
      end

      it "invalid locations" do
        [
          ["hetzner-hel2", nil],
          ["hetzner-hel2", "hetzner"],
          ["dp-mars-istanbul", "hetzner"]
        ].each do |location, provider|
          expect { described_class.validate_location(location, provider) }.to raise_error described_class::ValidationFailed
        end
      end
    end
  end
end
