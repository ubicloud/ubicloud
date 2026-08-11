# frozen_string_literal: true

require "digest"
require "json"
require_relative "../../common/lib/util"

# All CIDRs are baked into config.json by the control plane
# (see Prog::Postgres::PostgresServerNexus#network_metering_config).
class NetworkMetering
  CONFIG_PATH = "/etc/pg-metering/config.json"
  TABLE_PATH = "/etc/pg-metering/table.nft"
  SCHEMA_HASH_PATH = "/etc/pg-metering/schema.hash"
  PROM_PATH = "/var/lib/node_exporter/pg_net.prom"
  SYSTEMD_SRC_DIR = File.expand_path("../systemd", __dir__)
  SYSTEMD_DST_DIR = "/etc/systemd/system"
  UNIT_FILES = %w[pg-metering.service pg-metering-export.service pg-metering-export.timer].freeze
  ENABLED_UNITS = %w[pg-metering.service pg-metering-export.timer].freeze

  IP_VERSIONS = {"v4" => "ipv4", "v6" => "ipv6"}.freeze
  DIRECTIONS = {"in" => "ingress", "out" => "egress"}.freeze

  def initialize(logger)
    @logger = logger
  end

  def load_config
    config = JSON.parse(File.read(CONFIG_PATH))
    raise "unsupported config version #{config["version"].inspect}" unless config["version"] == 1
    config
  end

  def apply
    install_units
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
    r("nft -f :table_path", table_path: TABLE_PATH)
    safe_write_to_file(SCHEMA_HASH_PATH, new_hash)
    @logger.info("apply: reloaded (hash=#{new_hash[0, 8]}, rules=#{rules.size})")
  end

  # Copies static systemd units from the rhizome tree into /etc/systemd/system.
  # No-op when the on-disk content already matches, so it's safe to call on
  # every apply.
  def install_units
    changed = UNIT_FILES.reject do |name|
      src = File.join(SYSTEMD_SRC_DIR, name)
      dst = File.join(SYSTEMD_DST_DIR, name)
      File.exist?(dst) && File.read(src) == File.read(dst)
    end
    return if changed.empty?
    changed.each do |name|
      r("sudo install -m 0644 :src :dst",
        src: File.join(SYSTEMD_SRC_DIR, name),
        dst: File.join(SYSTEMD_DST_DIR, name))
    end
    r("sudo systemctl daemon-reload")
    ENABLED_UNITS.each do |name|
      if name.end_with?(".timer")
        r("sudo systemctl enable --now :name", name: name)
      else
        r("sudo systemctl enable :name", name: name)
      end
    end
    @logger.info("units: installed #{changed.join(", ")}")
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

    safe_write_to_file(PROM_PATH, lines.join("\n") + "\n")
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

  private

  def table_loaded_in_kernel?
    r("nft list table inet pg_metering > /dev/null 2>&1 && echo YES || echo NO").strip == "YES"
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
    ["v4", :saddr].freeze => "ip saddr", ["v4", :daddr].freeze => "ip daddr",
    ["v6", :saddr].freeze => "ip6 saddr", ["v6", :daddr].freeze => "ip6 daddr",
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
