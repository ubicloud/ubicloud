# frozen_string_literal: true

require "logger"
require "net/http"
require_relative "../../../lib/network_metering"

RSpec.describe NetworkMetering::Provider::Aws do
  let(:aws) { described_class.new }

  describe ".provided_ids" do
    it "advertises the flat AWS taxonomy (intra, tier1, excluded_svc)" do
      expect(described_class.provided_ids).to contain_exactly("intra_region", "inter_region_t1", "excluded_svc")
    end

    it "ignores provider_config (AWS has no config-dependent taxonomy)" do
      expect(described_class.provided_ids({"foo" => "bar"})).to contain_exactly("intra_region", "inter_region_t1", "excluded_svc")
    end
  end

  describe "#partition" do
    let(:ranges) do
      {
        "prefixes" => [
          {"ip_prefix" => "3.248.0.0/13", "region" => "eu-west-1", "service" => "EC2"},
          {"ip_prefix" => "52.218.0.0/17", "region" => "eu-west-1", "service" => "S3"},
          {"ip_prefix" => "3.0.0.0/9", "region" => "eu-west-1", "service" => "AMAZON"},
          {"ip_prefix" => "13.248.0.0/14", "region" => "GLOBAL", "service" => "AMAZON"},
          {"ip_prefix" => "205.251.192.0/19", "region" => "GLOBAL", "service" => "ROUTE53"},
          {"ip_prefix" => "3.5.140.0/22", "region" => "ap-northeast-2", "service" => "S3"},
          {"ip_prefix" => "13.124.0.0/16", "region" => "ap-northeast-2", "service" => "EC2"},
          {"ip_prefix" => "3.248.0.0/13", "region" => "eu-west-1", "service" => "EC2"}, # dup
        ],
        "ipv6_prefixes" => [
          {"ipv6_prefix" => "2a05:d018::/29", "region" => "eu-west-1", "service" => "EC2"},
          {"ipv6_prefix" => "2600:1f00::/33", "region" => "GLOBAL", "service" => "AMAZON"},
          {"ipv6_prefix" => "2001:4860::/32", "region" => "eu-west-1", "service" => "AMAZON"},
          {"ipv6_prefix" => "2406:da14::/32", "region" => "ap-northeast-2", "service" => "EC2"},
        ],
      }
    end
    let(:parts) { aws.classify_ranges(ranges, "eu-west-1") }

    it "puts same-region + GLOBAL S3/AMAZON into excluded_svc (v4)" do
      expect(parts["v4"]["excluded_svc"]).to contain_exactly("52.218.0.0/17", "3.0.0.0/9", "13.248.0.0/14")
    end

    it "puts same-region + GLOBAL non-excluded into intra_region (v4)" do
      expect(parts["v4"]["intra_region"]).to contain_exactly("3.248.0.0/13", "205.251.192.0/19")
    end

    it "puts all other-region v4 into inter_region (flat, no tier)" do
      expect(parts["v4"]["inter_region_t1"]).to contain_exactly("3.5.140.0/22", "13.124.0.0/16")
    end

    it "partitions v6 into the same buckets" do
      expect(parts["v6"]["intra_region"]).to include("2a05:d018::/29")
      expect(parts["v6"]["excluded_svc"]).to include("2600:1f00::/33", "2001:4860::/32")
      expect(parts["v6"]["inter_region_t1"]).to include("2406:da14::/32")
    end

    it "returns bucket keys for every set the rhizome expects" do
      %w[v4 v6].each do |fam|
        expect(parts[fam].keys).to contain_exactly("intra_region", "inter_region_t1", "excluded_svc")
      end
    end

    it "resolves AMAZON priority over EC2 when co-tagged" do
      ranges_dual = {"prefixes" => [
        {"ip_prefix" => "52.12.0.0/15", "region" => "us-west-2", "service" => "AMAZON"},
        {"ip_prefix" => "52.12.0.0/15", "region" => "us-west-2", "service" => "EC2"},
        {"ip_prefix" => "10.0.0.0/16", "region" => "us-west-2", "service" => "EC2"},
      ]}
      p = aws.classify_ranges(ranges_dual, "us-west-2")
      expect(p["v4"]["excluded_svc"]).to include("52.12.0.0/15")
      expect(p["v4"]["intra_region"]).not_to include("52.12.0.0/15")
      expect(p["v4"]["intra_region"]).to include("10.0.0.0/16")
    end

    it "excludes a prefix from inter_region when the same prefix is also listed for the local region" do
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
      payload = '{"prefixes":[]}'
      expect(Net::HTTP).to receive(:get).and_return(payload)
      expect(aws.fetch_ranges).to eq({"prefixes" => []})
    end
  end
end
