# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe OptionTreeFilter do
  describe ".filter" do
    it "returns all entries with no filters" do
      results = described_class.filter
      expect(results).not_to be_empty
      expect(results.first).to include(:provider, :location, :family, :size)
    end

    it "filters by provider" do
      results = described_class.filter(provider: "aws")
      expect(results).to all(include(provider: "aws"))
      expect(results).not_to be_empty
    end

    it "returns empty for non-matching provider" do
      expect(described_class.filter(provider: "nonexistent")).to be_empty
    end

    it "filters by location" do
      results = described_class.filter(provider: "aws", location: "ap-northeast-1")
      expect(results).to all(include(location: "ap-northeast-1"))
      expect(results).not_to be_empty
    end

    it "returns empty for non-matching location" do
      expect(described_class.filter(provider: "aws", location: "nonexistent")).to be_empty
    end

    it "filters by family" do
      results = described_class.filter(provider: "aws", location: "ap-northeast-1", family: "c6gd")
      expect(results).to all(include(family: "c6gd"))
      expect(results).not_to be_empty
    end

    it "returns empty for non-matching family" do
      expect(described_class.filter(provider: "aws", location: "ap-northeast-1", family: "nonexistent")).to be_empty
    end

    it "filters by size" do
      results = described_class.filter(provider: "aws", location: "ap-northeast-1", family: "c6gd", size: "c6gd.medium")
      expect(results.length).to eq(1)
      expect(results.first).to include(size: "c6gd.medium")
    end

    it "returns empty for non-matching size" do
      expect(described_class.filter(provider: "aws", location: "ap-northeast-1", family: "c6gd", size: "nonexistent")).to be_empty
    end
  end

  describe ".filter_data" do
    it "returns empty when data is nil" do
      expect(described_class.filter_data(nil)).to be_empty
    end

    it "returns empty when data has no providers" do
      expect(described_class.filter_data({})).to be_empty
    end

    it "skips providers with no locations" do
      data = {"providers" => {"aws" => {}}}
      expect(described_class.filter_data(data)).to be_empty
    end

    it "skips locations with no families" do
      data = {"providers" => {"aws" => {"locations" => {"us-east-1" => {}}}}}
      expect(described_class.filter_data(data)).to be_empty
    end

    it "skips families with no sizes" do
      data = {"providers" => {"aws" => {"locations" => {"us-east-1" => {"families" => {"m8gd" => {}}}}}}}
      expect(described_class.filter_data(data)).to be_empty
    end
  end

  describe ".data" do
    it "returns loaded YAML data" do
      expect(described_class.data).to be_a(Hash)
      expect(described_class.data).to include("providers")
    end
  end
end
