# frozen_string_literal: true

RSpec.describe BillingRate do
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
end
