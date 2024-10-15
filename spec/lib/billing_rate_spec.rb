# frozen_string_literal: true

RSpec.describe BillingRate do
  it "each rate has a unique ID" do
    expect(described_class.rates.map { _1["id"] }.size).to eq(described_class.rates.map { _1["id"] }.uniq.size)
  end

  describe ".line_item_description" do
    it "returns for VmCores" do
      expect(described_class.line_item_description("VmCores", "standard", 4)).to eq("standard-8 Virtual Machine")
    end

    it "returns for IPAddress" do
      expect(described_class.line_item_description("IPAddress", "IPv4", 1)).to eq("IPv4 Address")
    end

    it "raises exception for unknown type" do
      expect { described_class.line_item_description("NewType", "NewFamily", 1) }.to raise_error("BUG: Unknown resource type for line item description")
    end

    it "each resource type has a description" do
      described_class.rates.each do |rate|
        expect(described_class.line_item_description(rate["resource_type"], rate["resource_family"], 1)).not_to be_nil
      end
    end
  end

  describe ".line_item_usage" do
    it "returns usage by duration" do
      expect(described_class.line_item_usage("VmCores", "standard", 5, 1)).to eq("1 minutes")
    end

    it "returns usage by amount" do
      expect(described_class.line_item_usage("GitHubRunnerMinutes", "standard-2", 5, 1)).to eq("5 minutes")
    end

    it "returns usage by token" do
      expect(described_class.line_item_usage("InferenceTokens", "test-model", 10, 1)).to eq("10 tokens")
    end
  end

  it "can unambiguously find active rate" do
    expect(described_class.rates.group_by { [_1["resource_type"], _1["resource_family"], _1["location"], _1["active_from"]] }).not_to be_any { |k, v| v.count != 1 }
  end
end
