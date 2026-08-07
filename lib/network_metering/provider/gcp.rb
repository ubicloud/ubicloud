# frozen_string_literal: true

require "json"

module NetworkMetering
  module Provider
    # cloud.json (per-region ranges) + goog.json (public services).
    # Tiered inter-region buckets when gcp_tier_map is present, flat otherwise.
    class Gcp
      CLOUD_RANGES_URL = "https://www.gstatic.com/ipranges/cloud.json"
      GOOG_RANGES_URL = "https://www.gstatic.com/ipranges/goog.json"

      IP_VERSION_CIDR_KEYS = {"v4" => "ipv4Prefix", "v6" => "ipv6Prefix"}.freeze
      BASE_BUCKETS = %w[intra_region inter_region_t1 excluded_svc].freeze
      TIERED_BUCKETS = %w[inter_region_t2 inter_region_t3 inter_region_t4 inter_region_unknown].freeze

      def self.provided_ids(provider_config = {})
        return BASE_BUCKETS unless provider_config && provider_config["gcp_tier_map"]
        (BASE_BUCKETS + TIERED_BUCKETS).freeze
      end

      def fetch_ranges
        {
          "cloud" => JSON.parse(Excon.get(CLOUD_RANGES_URL, expects: 200).body),
          "goog" => JSON.parse(Excon.get(GOOG_RANGES_URL, expects: 200).body),
        }
      end

      def classify_ranges(ranges, region, provider_config = {})
        tier_map = provider_config&.[]("gcp_tier_map")
        IP_VERSION_CIDR_KEYS.transform_values { |cidr_key| classify_version_ranges(ranges, cidr_key, region, tier_map) }
      end

      private

      def classify_version_ranges(ranges, cidr_key, region, tier_map)
        excluded_cidrs = ranges["goog"]["prefixes"].filter_map { |p| p[cidr_key] }
        excluded_lookup = excluded_cidrs.each_with_object({}) { |c, h| h[c] = true }
        intra = []
        inter_tiered = {1 => [], 2 => [], 3 => [], 4 => []}
        inter_flat = []
        unknown = []

        regions_to_continents = tier_map&.fetch("regions_to_continents", {}) || {}
        tiers = if tier_map
          local_continent = regions_to_continents.fetch(region) { raise "region #{region.inspect} missing from GCP tier map" }
          tier_map.fetch("continents_to_continents_to_tiers").fetch(local_continent)
        end

        ranges["cloud"]["prefixes"].each do |p|
          cidr = p[cidr_key]
          next unless cidr
          # Present in both feeds: excluded_svc.
          next if excluded_lookup[cidr]
          scope = p["scope"].to_s
          if scope == region || scope == "global"
            intra << cidr
          elsif tier_map
            remote_continent = regions_to_continents[scope]
            tier = remote_continent && tiers[remote_continent]
            if tier
              inter_tiered[tier] << cidr
            else
              # Unmapped scope or missing tier row: leave it in
              # `unknown` for ops instead of guessing a band.
              unknown << cidr
            end
          else
            inter_flat << cidr
          end
        end

        parts = {"intra_region" => intra.uniq.sort, "excluded_svc" => excluded_cidrs.uniq.sort}
        if tier_map
          inter_tiered.each { |t, cidrs| parts["inter_region_t#{t}"] = cidrs.uniq.sort unless cidrs.empty? }
          parts["inter_region_unknown"] = unknown.uniq.sort unless unknown.empty?
        else
          parts["inter_region_t1"] = inter_flat.uniq.sort
        end
        parts
      end
    end
  end
end
