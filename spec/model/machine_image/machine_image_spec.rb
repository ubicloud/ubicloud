# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe MachineImage do
  describe ".base_name" do
    it "suffixes with 'eu' for hetzner-fsn1 and hetzner-hel1" do
      expect(described_class.base_name("ubuntu-noble", Location::HETZNER_FSN1_ID)).to eq("ubuntu-noble-eu")
      expect(described_class.base_name("ubuntu-noble", Location::HETZNER_HEL1_ID)).to eq("ubuntu-noble-eu")
    end

    it "suffixes with 'us' for leaseweb-wdc02" do
      expect(described_class.base_name("ubuntu-noble", Location::LEASEWEB_WDC02_ID)).to eq("ubuntu-noble-us")
    end

    it "returns nil for unsupported locations" do
      expect(described_class.base_name("ubuntu-noble", Location::GITHUB_RUNNERS_ID)).to be_nil
    end
  end
end
