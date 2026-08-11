# frozen_string_literal: true

require "spec_helper"

RSpec.describe NetworkMetering::Provider::Gcp do
  let(:gcp) { described_class.new }
  let(:tier_map) do
    {
      "regions_to_continents" => {
        "us-east1" => "northamerica", "us-west2" => "northamerica",
        "europe-west4" => "europe", "asia-east1" => "asia",
      },
      "continents_to_continents_to_tiers" => {
        "northamerica" => {"northamerica" => 1, "europe" => 2, "asia" => 3},
      },
    }
  end

  describe ".provided_ids" do
    it "returns flat taxonomy when no tier map" do
      expect(described_class.provided_ids({})).to contain_exactly("intra_region", "inter_region_t1", "excluded_svc")
    end

    it "adds tier ladder when tier map supplied" do
      expect(described_class.provided_ids({"gcp_tier_map" => tier_map})).to include(
        "inter_region_t2", "inter_region_t3", "inter_region_t4", "inter_region_unknown",
      )
    end
  end

  describe "#classify_ranges (flat)" do
    let(:ranges) do
      {
        "cloud" => {"prefixes" => [
          {"ipv4Prefix" => "34.1.0.0/16", "scope" => "us-east1"},
          {"ipv4Prefix" => "34.90.0.0/16", "scope" => "europe-west4"},
          {"ipv4Prefix" => "8.8.8.0/24", "scope" => "global"},
        ]},
        "goog" => {"prefixes" => [{"ipv4Prefix" => "8.8.4.0/24"}, {"ipv4Prefix" => "8.8.8.0/24"}]},
      }
    end
    let(:parts) { gcp.classify_ranges(ranges, "us-east1", {}) }

    it "same-region intra" do
      expect(parts["v4"]["intra_region"]).to include("34.1.0.0/16")
    end

    it "other-region flat inter_region_t1" do
      expect(parts["v4"]["inter_region_t1"]).to include("34.90.0.0/16")
    end

    it "goog.json overlap excluded" do
      expect(parts["v4"]["excluded_svc"]).to include("8.8.8.0/24")
      expect(parts["v4"]["intra_region"]).not_to include("8.8.8.0/24")
    end
  end

  describe "#classify_ranges (tiered)" do
    let(:ranges) do
      {
        "cloud" => {"prefixes" => [
          {"ipv4Prefix" => "34.90.0.0/16", "scope" => "europe-west4"},
          {"ipv4Prefix" => "34.80.0.0/16", "scope" => "asia-east1"},
          {"ipv4Prefix" => "34.99.0.0/16", "scope" => "unknown-newregion1"},
        ]},
        "goog" => {"prefixes" => []},
      }
    end
    let(:parts) { gcp.classify_ranges(ranges, "us-east1", {"gcp_tier_map" => tier_map}) }

    it "europe-west4 -> tier2" do
      expect(parts["v4"]["inter_region_t2"]).to include("34.90.0.0/16")
    end

    it "asia-east1 -> tier3" do
      expect(parts["v4"]["inter_region_t3"]).to include("34.80.0.0/16")
    end

    it "unmapped scope -> inter_region_unknown" do
      expect(parts["v4"]["inter_region_unknown"]).to include("34.99.0.0/16")
    end

    it "raises when local region is missing from map" do
      expect { gcp.classify_ranges(ranges, "fictional-1", {"gcp_tier_map" => tier_map}) }.to raise_error(/missing from GCP tier map/)
    end
  end

  describe "#classify_ranges with nil provider_config" do
    it "treats nil provider_config as flat" do
      ranges = {"cloud" => {"prefixes" => [{"ipv4Prefix" => "34.1.0.0/16", "scope" => "us-east1"}]}, "goog" => {"prefixes" => []}}
      p = gcp.classify_ranges(ranges, "us-east1", nil)
      expect(p["v4"]["intra_region"]).to include("34.1.0.0/16")
    end
  end

  describe "#fetch_ranges" do
    it "fetches cloud.json and goog.json" do
      stub_request(:get, described_class::CLOUD_RANGES_URL).to_return(status: 200, body: '{"prefixes":[]}')
      stub_request(:get, described_class::GOOG_RANGES_URL).to_return(status: 200, body: '{"prefixes":[]}')
      expect(gcp.fetch_ranges).to eq({"cloud" => {"prefixes" => []}, "goog" => {"prefixes" => []}})
    end
  end
end
