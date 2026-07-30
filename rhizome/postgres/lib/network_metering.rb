# frozen_string_literal: true

require "digest"
require "json"
require_relative "../../common/lib/util"

# Renders nftables from config.json, refreshes provider ranges,
# exports counters as node_exporter textfile metrics.
class NetworkMetering
  CONFIG_PATH = "/etc/pg-metering/config.json"
  TABLE_PATH = "/etc/pg-metering/table.nft"
  RANGES_SETS_PATH = "/etc/pg-metering/ranges-sets.nft"
  SCHEMA_HASH_PATH = "/etc/pg-metering/schema.hash"
  PROM_PATH = "/var/lib/node_exporter/pg_net.prom"

  IP_VERSIONS = {"v4" => "ipv4", "v6" => "ipv6"}.freeze
  DIRECTIONS = {"in" => "ingress", "out" => "egress"}.freeze

  module Provider; end
  module CidrSource; end

  PROVIDERS = {}
  CIDR_SOURCES = {}

  def self.provider_for(name)
    PROVIDERS.fetch(name) { raise "unknown metering provider #{name.inspect}" }.new
  end

  def self.feeder_for(source_name, config)
    if source_name == "provider"
      provider_for(config.fetch("provider"))
    elsif CIDR_SOURCES.key?(source_name)
      CIDR_SOURCES.fetch(source_name).new
    else
      raise "unknown CIDR source #{source_name.inspect} (not in PROVIDERS or CIDR_SOURCES)"
    end
  end

  def initialize(logger)
    @logger = logger
  end

  def load_config
    config = JSON.parse(File.read(CONFIG_PATH))
    raise "unsupported config version #{config["version"].inspect}" unless config["version"] == 1
    config
  end

  def apply
    config = load_config
    rules = config.fetch("rules").sort_by { |r| r["priority"] }

    txt = render_table(rules)
    new_hash = Digest::SHA256.hexdigest(txt)
    live_hash = File.exist?(SCHEMA_HASH_PATH) ? File.read(SCHEMA_HASH_PATH).strip : ""

    if live_hash == new_hash && File.exist?(TABLE_PATH) && table_loaded_in_kernel?
      @logger.info("apply: no change, skipping (hash=#{new_hash[0, 8]})")
      return
    end

    safe_write_to_file(TABLE_PATH, txt)
    r "nft -f #{TABLE_PATH}"
    # Restore the last-good ranges cache. If it references dropped sets
    # after a schema change, swallow; the next refresh will repopulate.
    if File.exist?(RANGES_SETS_PATH)
      begin
        r "nft -f #{RANGES_SETS_PATH}"
      rescue => ex
        @logger.warn("apply: stale ranges-sets cache failed to reapply: #{ex.message}")
      end
    end
    safe_write_to_file(SCHEMA_HASH_PATH, new_hash)
    @logger.info("apply: reloaded (hash=#{new_hash[0, 8]}, rules=#{rules.size})")
  end

  def refresh
    config = load_config
    merged = {"v4" => {}, "v6" => {}}
    all_ids = []

    rules_by_source(config).each do |source_name, source_rule_ids|
      feeder = self.class.feeder_for(source_name, config)
      unknown = source_rule_ids - feeder.class.provided_ids(config["provider_config"] || {})
      raise "feeder #{feeder.class.name} does not know how to populate #{unknown.inspect}" unless unknown.empty?

      parts = feeder.classify_ranges(feeder.fetch_ranges, config.fetch("region"), config["provider_config"] || {})

      # Add-on feeders may be sparse; only guard the main provider.
      guard_degenerate_partition(parts, source_rule_ids) if source_name == "provider"

      IP_VERSIONS.each_key { |fam| merged[fam].merge!((parts[fam] || {}).slice(*source_rule_ids)) }
      all_ids.concat(source_rule_ids)
    end

    txn = render_sets_transaction(merged, all_ids)

    # Stage first so a failed nft -f preserves the last-good cache.
    staging = "#{RANGES_SETS_PATH}.new"
    safe_write_to_file(staging, txn)
    r "nft -f #{staging}"
    File.rename(staging, RANGES_SETS_PATH)

    sizes = IP_VERSIONS.keys.map { |fam| merged[fam].map { |k, v| "#{fam}.#{k}=#{v.size}" } }.flatten.join(" ")
    @logger.info("refreshed ranges sets: region=#{config["region"]} #{sizes}")
  end

  def rules_by_source(config)
    config.fetch("rules")
      .select { |r| r["source"] }
      .group_by { |r| r["source"] }
      .transform_values { |rs| rs.map { |r| r["id"] } }
  end

  def export
    counters = JSON.parse(r("nft -j list counters table inet pg_metering"))["nftables"]
      .filter_map { |o| o["counter"] }
      .to_h { |c| [c["name"], c["bytes"]] }

    lines = [
      "# HELP pg_net_bytes_total Bytes per billing bucket, direction and IP version (cumulative).",
      "# TYPE pg_net_bytes_total counter",
    ]
    counters.each do |name, bytes|
      md = name.match(/\A(?<label>.+)_(?<fam>v[46])_(?<dir>in|out)\z/)
      next unless md
      lines << %(pg_net_bytes_total{bucket="#{md[:label]}",direction="#{DIRECTIONS[md[:dir]]}",ip_version="#{IP_VERSIONS[md[:fam]]}"} #{bytes})
    end

    age = File.exist?(RANGES_SETS_PATH) ? (Time.now - File.mtime(RANGES_SETS_PATH)).to_i : -1
    lines << "# HELP pg_net_ranges_sets_age_seconds Seconds since provider IP range sets were refreshed."
    lines << "# TYPE pg_net_ranges_sets_age_seconds gauge"
    lines << "pg_net_ranges_sets_age_seconds #{age}"

    File.write("#{PROM_PATH}.tmp", lines.join("\n") + "\n")
    File.rename("#{PROM_PATH}.tmp", PROM_PATH)
  end

  def render_table(rules)
    body = [
      render_sets(rules),
      render_counters(rules),
      render_dispatch("ingress", "input", "iifname"),
      render_dispatch("egress", "output", "oifname"),
      render_version_chains(rules),
    ].join("\n\n")

    <<~NFT
      table inet pg_metering;
      delete table inet pg_metering;
      table inet pg_metering {
      #{body}
      }
    NFT
  end

  def render_sets_transaction(parts, generated_ids)
    IP_VERSIONS.keys.flat_map { |fam|
      generated_ids.map { |id| "flush set inet pg_metering #{id}_#{fam}\n" }
    }.join + IP_VERSIONS.each_key.flat_map { |fam|
      (parts[fam] || {}).map { |id, cidrs|
        cidrs.empty? ? "" : "add element inet pg_metering #{id}_#{fam} { #{cidrs.join(", ")} }\n"
      }
    }.join
  end

  private

  def table_loaded_in_kernel?
    r("nft list table inet pg_metering > /dev/null 2>&1 && echo YES || echo NO").strip == "YES"
  end

  # v4 must be fully populated (else traffic drops to public_internet).
  # v6 may be sparse but not entirely empty.
  def guard_degenerate_partition(parts, source_rule_ids)
    v4 = (parts["v4"] || {}).slice(*source_rule_ids)
    if v4.empty? || v4.values.any?(&:empty?)
      raise "refusing to apply degenerate range sets (v4: #{(parts["v4"] || {}).map { |k, v| "#{k}=#{v.size}" }.join(" ")})"
    end
    v6 = (parts["v6"] || {}).slice(*source_rule_ids)
    if v6.empty? || v6.values.all?(&:empty?)
      raise "refusing to apply degenerate range sets (v6: #{(parts["v6"] || {}).map { |k, v| "#{k}=#{v.size}" }.join(" ")})"
    end
  end

  def render_sets(rules)
    rules.reject { |r| r["type"] == "catchall" }.flat_map { |r|
      IP_VERSIONS.keys.map { |fam| render_set(r, fam) }
    }.join("\n")
  end

  def render_set(rule, fam)
    addr_type = (fam == "v4") ? "ipv4_addr" : "ipv6_addr"
    elements = rule.dig("cidrs", fam) || []
    return "set #{rule["id"]}_#{fam} { type #{addr_type}; flags interval; auto-merge; }" if elements.empty?
    <<~SET
      set #{rule["id"]}_#{fam} {
        type #{addr_type}
        flags interval
        auto-merge
        elements = { #{elements.join(", ")} }
      }
    SET
  end

  def render_counters(rules)
    rules.map { |r| r["label"] }.uniq.flat_map { |label|
      IP_VERSIONS.keys.flat_map { |fam| ["counter #{label}_#{fam}_in {}", "counter #{label}_#{fam}_out {}"] }
    }.join("\n")
  end

  def render_dispatch(direction, hook, iface)
    <<~CHAIN
      chain #{direction} {
        type filter hook #{hook} priority filter; policy accept;
        #{iface} "lo" accept
        meta l4proto != tcp accept
        meta nfproto ipv4 goto #{direction}_v4
        meta nfproto ipv6 goto #{direction}_v6
      }
    CHAIN
  end

  def render_version_chains(rules)
    IP_VERSIONS.keys.flat_map { |fam|
      [render_version_chain("ingress", fam, :saddr, "in", rules),
        render_version_chain("egress", fam, :daddr, "out", rules)]
    }.join("\n")
  end

  ADDR_EXPRS = {
    ["v4", :saddr] => "ip saddr", ["v4", :daddr] => "ip daddr",
    ["v6", :saddr] => "ip6 saddr", ["v6", :daddr] => "ip6 daddr",
  }.freeze

  def render_version_chain(direction, fam, addr_key, dir_suffix, rules)
    addr = ADDR_EXPRS.fetch([fam, addr_key])
    lines = rules.map { |r|
      counter = "#{r["label"]}_#{fam}_#{dir_suffix}"
      if r["type"] == "catchall"
        "  counter name #{counter}"
      else
        "  #{addr} @#{r["id"]}_#{fam} counter name #{counter} accept"
      end
    }
    <<~CHAIN
      chain #{direction}_#{fam} {
      #{lines.join("\n")}
      }
    CHAIN
  end
end

Dir[File.join(__dir__, "network_metering", "**", "*.rb")].sort.each { |f| require_relative f }
