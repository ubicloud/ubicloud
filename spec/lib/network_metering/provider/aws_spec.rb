# frozen_string_literal: true

require "spec_helper"

RSpec.describe NetworkMetering::Provider::Aws do
  let(:aws) { described_class.new }

  describe ".provided_ids" do
    it "advertises flat AWS taxonomy" do
      expect(described_class.provided_ids).to contain_exactly("intra_region", "inter_region_t1", "excluded_svc")
    end

    it "ignores provider_config" do
      expect(described_class.provided_ids({"foo" => "bar"})).to contain_exactly("intra_region", "inter_region_t1", "excluded_svc")
    end
  end

  describe "#classify_ranges" do
    let(:ranges) do
      {
        "prefixes" => [
          {"ip_prefix" => "3.248.0.0/13", "region" => "eu-west-1", "service" => "EC2"},
          {"ip_prefix" => "52.218.0.0/17", "region" => "eu-west-1", "service" => "S3"},
          {"ip_prefix" => "13.248.0.0/14", "region" => "GLOBAL", "service" => "AMAZON"},
          {"ip_prefix" => "13.124.0.0/16", "region" => "ap-northeast-2", "service" => "EC2"},
        ],
        "ipv6_prefixes" => [
          {"ipv6_prefix" => "2a05:d018::/29", "region" => "eu-west-1", "service" => "EC2"},
          {"ipv6_prefix" => "2600:1f00::/33", "region" => "GLOBAL", "service" => "AMAZON"},
        ],
      }
    end
    let(:parts) { aws.classify_ranges(ranges, "eu-west-1") }

    it "puts same-region + GLOBAL S3/AMAZON into excluded_svc" do
      expect(parts["v4"]["excluded_svc"]).to contain_exactly("52.218.0.0/17", "13.248.0.0/14")
    end

    it "puts same-region non-excluded into intra_region" do
      expect(parts["v4"]["intra_region"]).to include("3.248.0.0/13")
    end

    it "puts other-region into inter_region_t1" do
      expect(parts["v4"]["inter_region_t1"]).to include("13.124.0.0/16")
    end

    it "resolves AMAZON priority over EC2 when co-tagged" do
      dual = {"prefixes" => [
        {"ip_prefix" => "52.12.0.0/15", "region" => "us-west-2", "service" => "AMAZON"},
        {"ip_prefix" => "52.12.0.0/15", "region" => "us-west-2", "service" => "EC2"},
      ]}
      p = aws.classify_ranges(dual, "us-west-2")
      expect(p["v4"]["excluded_svc"]).to include("52.12.0.0/15")
      expect(p["v4"]["intra_region"]).not_to include("52.12.0.0/15")
    end

    it "excludes a prefix from inter when the same prefix is also listed for the local region" do
      overlap = {"prefixes" => [
        {"ip_prefix" => "3.5.140.0/22", "region" => "eu-west-1", "service" => "EC2"},
        {"ip_prefix" => "3.5.140.0/22", "region" => "ap-northeast-2", "service" => "EC2"},
      ]}
      p = aws.classify_ranges(overlap, "eu-west-1")
      expect(p["v4"]["intra_region"]).to include("3.5.140.0/22")
      expect(p["v4"]["inter_region_t1"]).not_to include("3.5.140.0/22")
    end

    it "skips entries with missing cidr" do
      p = aws.classify_ranges({"prefixes" => [{"region" => "eu-west-1", "service" => "EC2"}]}, "eu-west-1")
      expect(p["v4"]["intra_region"]).to eq([])
    end
  end

  describe "#fetch_ranges" do
    it "fetches and parses JSON from IP_RANGES_URL" do
      stub_request(:get, described_class::IP_RANGES_URL).to_return(status: 200, body: '{"prefixes":[]}')
      expect(aws.fetch_ranges).to eq({"prefixes" => []})
    end
  end
end
