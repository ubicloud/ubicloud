# frozen_string_literal: true

require "rspec"
require_relative "../../lib/option_tree_filter"

RSpec.describe OptionTreeFilter do
  describe ".filter" do
    context "when filtering by provider" do
      it "returns only entries from the specified provider" do
        results = described_class.filter(provider: "aws")
        expect(results).to all(include(provider: "aws"))
        expect(results).not_to be_empty
      end

      it "returns empty when provider does not exist" do
        results = described_class.filter(provider: "nonexistent-provider")
        expect(results).to be_empty
      end
    end

    context "when filtering by location" do
      it "returns only entries from the specified location" do
        results = described_class.filter(provider: "aws", location: "us-east-1")
        expect(results).to all(include(location: "us-east-1"))
        expect(results).not_to be_empty
      end

      it "returns empty when location does not exist" do
        results = described_class.filter(provider: "aws", location: "nonexistent-location")
        expect(results).to be_empty
      end
    end

    context "when filtering by family" do
      it "returns only entries from the specified family" do
        results = described_class.filter(provider: "aws", location: "us-east-1", family: "m6gd")
        expect(results).to all(include(family: "m6gd"))
        expect(results).not_to be_empty
      end

      it "returns empty when family does not exist" do
        results = described_class.filter(provider: "aws", location: "us-east-1", family: "nonexistent-family")
        expect(results).to be_empty
      end
    end

    context "when filtering by size" do
      it "returns only entries with the specified size" do
        results = described_class.filter(provider: "aws", location: "us-east-1", family: "m6gd", size: "m6gd.large")
        expect(results.size).to eq(1)
        expect(results.first).to include(size: "m6gd.large")
      end

      it "returns empty when size does not exist" do
        results = described_class.filter(provider: "aws", location: "us-east-1", family: "m6gd", size: "nonexistent-size")
        expect(results).to be_empty
      end
    end

    context "when combining filters" do
      it "filters by provider, location, family, and size" do
        results = described_class.filter(provider: "aws", location: "us-east-1", family: "m6gd", size: "m6gd.large")
        expect(results.size).to eq(1)
        expect(results.first).to include(provider: "aws", location: "us-east-1", family: "m6gd", size: "m6gd.large")
      end
    end
  end
end
