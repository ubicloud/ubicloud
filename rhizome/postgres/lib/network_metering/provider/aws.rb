# frozen_string_literal: true

require "json"
require "net/http"
require "uri"

class NetworkMetering
  module Provider
    # Flat inter-region pricing. AMAZON/S3 prefixes are AWS-internal
    # and land in excluded_svc.
    class Aws
      IP_RANGES_URL = "https://ip-ranges.amazonaws.com/ip-ranges.json"
      # Lower wins on co-tagged prefixes.
      SERVICE_PRIORITIES = {"S3" => -1, "AMAZON" => 1, "EC2" => 2}.freeze
      EXCLUDED_SERVICES = ["S3", "AMAZON"].freeze
      # Rank unlisted services above EC2 so they can't displace AMAZON.
      UNLISTED_PRIORITY = 100

      IP_VERSION_SOURCES = {
        "v4" => {top_key: "prefixes", cidr_key: "ip_prefix"},
        "v6" => {top_key: "ipv6_prefixes", cidr_key: "ipv6_prefix"},
      }.freeze

      def self.provided_ids(_provider_config = {})
        %w[intra_region inter_region_t1 excluded_svc]
      end

      def fetch_ranges
        JSON.parse(Net::HTTP.get(URI(IP_RANGES_URL)))
      end

      # GLOBAL is anycast; count it as same-region.
      def classify_ranges(ranges, region, _provider_config = {})
        IP_VERSION_SOURCES.transform_values { |src| classify_version_ranges(ranges[src[:top_key]] || [], src[:cidr_key], region) }
      end

      private

      def classify_version_ranges(entries, cidr_key, region)
        same_region = {}
        inter = []
        entries.each do |p|
          cidr, svc, reg = p[cidr_key], p["service"], p["region"]
          next unless cidr
          if reg == region || reg == "GLOBAL"
            (same_region[cidr] ||= []) << svc
          else
            inter << cidr
          end
        end
        excluded, intra = [], []
        same_region.each do |cidr, svcs|
          winner = svcs.min_by { |s| SERVICE_PRIORITIES.fetch(s, UNLISTED_PRIORITY) }
          (EXCLUDED_SERVICES.include?(winner) ? excluded : intra) << cidr
        end
        # Same-region wins over inter for prefixes listed under both.
        inter -= same_region.keys
        {"intra_region" => intra.uniq.sort, "inter_region_t1" => inter.uniq.sort, "excluded_svc" => excluded.uniq.sort}
      end
    end
  end

  PROVIDERS["aws"] = Provider::Aws
end
