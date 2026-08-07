# frozen_string_literal: true

require "net/http"
require_relative "../../../lib/network_metering"

RSpec.describe NetworkMetering::Provider::Gcp do
  let(:gcp) { described_class.new }
  let(:tier_map) do
    {
      "regions_to_continents" => {
        "us-east1" => "northamerica", "us-west2" => "northamerica",
        "europe-west4" => "europe", "asia-east1" => "asia",
        "me-central1" => "middleeast",
      },
      "continents_to_continents_to_tiers" => {
        "northamerica" => {"northamerica" => 1, "europe" => 2, "asia" => 3, "middleeast" => 4},
        "europe" => {"northamerica" => 2, "europe" => 1, "asia" => 3, "middleeast" => 4},
      },
    }
  end

  describe ".provided_ids" do
    it "returns the flat taxonomy when no tier map supplied" do
      expect(described_class.provided_ids({})).to contain_exactly("intra_region", "inter_region_t1", "excluded_svc")
    end

    it "adds the tier ladder when provider_config['gcp_tier_map'] is present" do
      expect(described_class.provided_ids({"gcp_tier_map" => tier_map})).to include(
        "inter_region_t2", "inter_region_t3", "inter_region_t4", "inter_region_unknown",
      )
    end
  end

  describe "#partition (flat, no tier map)" do
    let(:cloud_prefixes) do
      [
        {"ipv4Prefix" => "34.1.0.0/16", "scope" => "us-east1"},
        {"ipv4Prefix" => "8.8.8.0/24", "scope" => "global"},
        {"ipv4Prefix" => "34.90.0.0/16", "scope" => "europe-west4"},
        {"ipv4Prefix" => "34.2.0.0/16", "scope" => "us-west2"},
      ]
    end
    let(:goog_prefixes) { [{"ipv4Prefix" => "8.8.4.0/24"}, {"ipv4Prefix" => "8.8.8.0/24"}] }
    let(:ranges) { {"cloud" => {"prefixes" => cloud_prefixes}, "goog" => {"prefixes" => goog_prefixes}} }
    let(:parts) { gcp.classify_ranges(ranges, "us-east1", {}) }

    it "puts same-region into intra_region" do
      expect(parts["v4"]["intra_region"]).to include("34.1.0.0/16")
    end

    it "puts other-region into flat inter_region_t1" do
      expect(parts["v4"]["inter_region_t1"]).to contain_exactly("34.90.0.0/16", "34.2.0.0/16")
    end

    it "prefers excluded_svc over intra_region for overlapping prefixes" do
      expect(parts["v4"]["excluded_svc"]).to include("8.8.8.0/24")
      expect(parts["v4"]["intra_region"]).not_to include("8.8.8.0/24")
    end
  end

  describe "#partition (tiered, with tier map)" do
    let(:cloud_prefixes) do
      [
        {"ipv4Prefix" => "34.1.0.0/16", "scope" => "us-east1"},
        {"ipv4Prefix" => "34.2.0.0/16", "scope" => "us-west2"},
        {"ipv4Prefix" => "34.90.0.0/16", "scope" => "europe-west4"},
        {"ipv4Prefix" => "34.80.0.0/16", "scope" => "asia-east1"},
        {"ipv4Prefix" => "34.101.0.0/16", "scope" => "me-central1"},
        {"ipv4Prefix" => "34.99.0.0/16", "scope" => "unknown-newregion1"},
      ]
    end
    let(:ranges) { {"cloud" => {"prefixes" => cloud_prefixes}, "goog" => {"prefixes" => []}} }
    let(:parts) { gcp.classify_ranges(ranges, "us-east1", {"gcp_tier_map" => tier_map}) }

    it "classifies us-west2 as tier1 from us-east1 (same continent)" do
      expect(parts["v4"]["inter_region_t1"]).to include("34.2.0.0/16")
    end

    it "classifies europe-west4 as tier2 from us-east1" do
      expect(parts["v4"]["inter_region_t2"]).to include("34.90.0.0/16")
    end

    it "classifies asia-east1 as tier3 from us-east1" do
      expect(parts["v4"]["inter_region_t3"]).to include("34.80.0.0/16")
    end

    it "classifies me-central1 as tier4 from us-east1" do
      expect(parts["v4"]["inter_region_t4"]).to include("34.101.0.0/16")
    end

    it "puts unmapped scope into inter_region_unknown" do
      expect(parts["v4"]["inter_region_unknown"]).to include("34.99.0.0/16")
    end

    it "routes a known continent with no tier row to inter_region_unknown" do
      # us-east1 is in northamerica; if the northamerica-to-middleeast row
      # is missing, the prefix must stay visible in `unknown` instead of
      # being silently billed at a guessed tier.
      stripped = {"regions_to_continents" => tier_map["regions_to_continents"],
                  "continents_to_continents_to_tiers" => {"northamerica" => {"northamerica" => 1}}}
      p = gcp.classify_ranges(ranges, "us-east1", {"gcp_tier_map" => stripped})
      expect(p["v4"]["inter_region_unknown"]).to include("34.101.0.0/16")
      expect(p["v4"]["inter_region_t4"] || []).not_to include("34.101.0.0/16")
    end

    it "raises when local region is missing from the tier map" do
      expect { gcp.classify_ranges(ranges, "fictional-1", {"gcp_tier_map" => tier_map}) }.to raise_error(/missing from GCP tier map/)
    end
  end

  describe "provider registration" do
    it "registers itself under 'gcp'" do
      expect(NetworkMetering::PROVIDERS["gcp"]).to eq(described_class)
    end
  end

  describe "#classify_ranges with nil provider_config" do
    it "treats nil provider_config as flat (no tier map)" do
      ranges = {"cloud" => {"prefixes" => [{"ipv4Prefix" => "34.1.0.0/16", "scope" => "us-east1"}]}, "goog" => {"prefixes" => []}}
      p = gcp.classify_ranges(ranges, "us-east1", nil)
      expect(p["v4"]["intra_region"]).to include("34.1.0.0/16")
    end
  end

  describe "#fetch_ranges" do
    it "fetches cloud.json and goog.json" do
      expect(Net::HTTP).to receive(:get).with(URI(described_class::CLOUD_RANGES_URL)).and_return('{"prefixes":[]}')
      expect(Net::HTTP).to receive(:get).with(URI(described_class::GOOG_RANGES_URL)).and_return('{"prefixes":[]}')
      expect(gcp.fetch_ranges).to eq({"cloud" => {"prefixes" => []}, "goog" => {"prefixes" => []}})
    end
  end
end
