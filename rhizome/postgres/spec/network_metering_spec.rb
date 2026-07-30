# frozen_string_literal: true

require "logger"
require "json"
require_relative "../lib/network_metering"

RSpec.describe NetworkMetering do
  let(:logger) { instance_double(Logger, info: nil, warn: nil, error: nil) }
  let(:nm) { described_class.new(logger) }

  let(:base_config) do
    {
      "version" => 1,
      "region" => "eu-west-1",
      "provider" => "aws",
      "rules" => [
        {"id" => "internal", "priority" => 10, "label" => "internal",
         "cidrs" => {"v4" => ["10.0.0.0/8"], "v6" => ["fc00::/7"]}},
        {"id" => "public_internet", "priority" => 999, "label" => "public_internet", "type" => "catchall"},
      ],
      "provider_config" => {},
    }
  end

  describe ".provider_for" do
    it "returns an instance for a known provider name" do
      expect(described_class.provider_for("aws")).to be_a(NetworkMetering::Provider::Aws)
    end

    it "raises for an unknown provider name" do
      expect { described_class.provider_for("azure") }.to raise_error(/unknown metering provider "azure"/)
    end
  end

  describe ".feeder_for" do
    it "returns the main provider for source='provider'" do
      expect(described_class.feeder_for("provider", "provider" => "aws")).to be_a(NetworkMetering::Provider::Aws)
    end

    it "resolves a named source from CIDR_SOURCES" do
      fake_feeder = Class.new
      stub_const("NetworkMetering::CIDR_SOURCES", {"clickpipes" => fake_feeder})
      expect(described_class.feeder_for("clickpipes", {})).to be_a(fake_feeder)
    end

    it "raises loudly on an unknown source name" do
      expect { described_class.feeder_for("bogus", {}) }.to raise_error(/unknown CIDR source "bogus"/)
    end
  end

  describe "#load_config" do
    it "parses the config file" do
      allow(File).to receive(:read).with(described_class::CONFIG_PATH).and_return(JSON.generate(base_config))
      expect(nm.load_config).to include("version" => 1, "region" => "eu-west-1")
    end

    it "raises on unsupported version" do
      allow(File).to receive(:read).with(described_class::CONFIG_PATH).and_return(JSON.generate(base_config.merge("version" => 2)))
      expect { nm.load_config }.to raise_error(/unsupported config version 2/)
    end
  end

  describe "#render_table" do
    it "declares atomic table+delete+define prefix" do
      table = nm.render_table(base_config["rules"])
      expect(table).to start_with("table inet pg_metering;\ndelete table inet pg_metering;\ntable inet pg_metering {\n")
    end

    it "renders a set per non-catchall rule × IP version" do
      table = nm.render_table(base_config["rules"])
      expect(table).to include("set internal_v4 {")
      expect(table).to include("set internal_v6 {")
      # catchall does NOT get a set
      expect(table).not_to include("set public_internet_v4")
      expect(table).not_to include("set public_internet_v6")
    end

    it "embeds cidrs into non-catchall sets" do
      table = nm.render_table(base_config["rules"])
      expect(table).to include("elements = { 10.0.0.0/8 }")
      expect(table).to include("elements = { fc00::/7 }")
    end

    it "declares counters for every unique label × ip_version × direction" do
      table = nm.render_table(base_config["rules"])
      # 2 labels × 2 v × 2 dir = 8
      expect(table.scan(/^counter /).size).to eq(8)
    end

    it "renders catchall as counter-only rule (no set match, no accept)" do
      table = nm.render_table(base_config["rules"])
      expect(table).to match(/chain ingress_v4 \{[^}]*  counter name public_internet_v4_in\n\}/m)
      expect(table).to match(/chain egress_v6 \{[^}]*  counter name public_internet_v6_out\n\}/m)
    end

    it "orders chain rules by priority (low first)" do
      rules = [
        {"id" => "z", "priority" => 500, "label" => "z", "cidrs" => {"v4" => ["1.2.3.4/32"], "v6" => []}},
        {"id" => "a", "priority" => 5, "label" => "a", "cidrs" => {"v4" => ["5.6.7.8/32"], "v6" => []}},
      ]
      table = nm.render_table(rules.sort_by { |r| r["priority"] })
      v4_chain = table[/chain ingress_v4 \{[^}]+\}/m]
      expect(v4_chain.index("@a_v4")).to be < v4_chain.index("@z_v4")
    end

    it "handles empty cidrs for a family with an empty-body set declaration" do
      rules = [{"id" => "control_plane", "priority" => 20, "label" => "control_plane",
                "cidrs" => {"v4" => ["1.2.3.4/32"], "v6" => []}}]
      table = nm.render_table(rules)
      expect(table).to include("set control_plane_v6 { type ipv6_addr; flags interval; auto-merge; }")
    end
  end

  describe "#render_sets_transaction" do
    it "flushes every generated set × family and adds elements for non-empty entries" do
      parts = {
        "v4" => {"intra_region" => ["4.5.0.0/16"], "inter_region" => ["9.8.0.0/14"], "excluded_svc" => ["1.2.3.0/24"]},
        "v6" => {"intra_region" => ["2600:1f00::/33"], "excluded_svc" => ["2001:4860::/32"]},
      }
      gen_ids = %w[intra_region inter_region excluded_svc]
      txn = nm.render_sets_transaction(parts, gen_ids)
      %w[v4 v6].each do |fam|
        gen_ids.each do |id|
          expect(txn).to include("flush set inet pg_metering #{id}_#{fam}")
        end
      end
      expect(txn).to include("add element inet pg_metering intra_region_v4 { 4.5.0.0/16 }")
      expect(txn).to include("add element inet pg_metering excluded_svc_v6 { 2001:4860::/32 }")
      expect(txn).not_to include("add element inet pg_metering inter_region_v6")
    end
  end

  describe "#apply" do
    before { allow(nm).to receive(:load_config).and_return(base_config) }

    it "renders and applies when hash differs" do
      allow(File).to receive(:exist?).and_return(false)
      expect(nm).to receive(:safe_write_to_file).with(described_class::TABLE_PATH, anything)
      expect(nm).to receive(:r).with("nft -f #{described_class::TABLE_PATH}")
      expect(nm).to receive(:safe_write_to_file).with(described_class::SCHEMA_HASH_PATH, /\A[0-9a-f]{64}\z/)
      nm.apply
    end

    it "skips when hash matches and the kernel table is loaded" do
      cur_hash = Digest::SHA256.hexdigest(nm.render_table(base_config["rules"]))
      allow(File).to receive(:exist?).and_return(true)
      allow(File).to receive(:read).with(described_class::SCHEMA_HASH_PATH).and_return(cur_hash)
      allow(nm).to receive(:r).with(/nft list table/).and_return("YES\n")
      expect(nm).not_to receive(:safe_write_to_file)
      expect(nm).not_to receive(:r).with(/nft -f/)
      nm.apply
    end

    it "reloads when the hash matches but the kernel table is missing" do
      cur_hash = Digest::SHA256.hexdigest(nm.render_table(base_config["rules"]))
      allow(File).to receive(:exist?).with(described_class::SCHEMA_HASH_PATH).and_return(true)
      allow(File).to receive(:exist?).with(described_class::TABLE_PATH).and_return(true)
      allow(File).to receive(:exist?).with(described_class::RANGES_SETS_PATH).and_return(false)
      allow(File).to receive(:read).with(described_class::SCHEMA_HASH_PATH).and_return(cur_hash)
      allow(nm).to receive(:r).with(/nft list table/).and_return("NO\n")
      expect(nm).to receive(:safe_write_to_file).with(described_class::TABLE_PATH, anything)
      expect(nm).to receive(:r).with("nft -f #{described_class::TABLE_PATH}")
      expect(nm).to receive(:safe_write_to_file).with(described_class::SCHEMA_HASH_PATH, /\A[0-9a-f]{64}\z/)
      nm.apply
    end

    it "logs and continues when the stale ranges-sets cache fails to reapply" do
      allow(File).to receive(:exist?).with(described_class::SCHEMA_HASH_PATH).and_return(false)
      allow(File).to receive(:exist?).with(described_class::TABLE_PATH).and_return(false)
      allow(File).to receive(:exist?).with(described_class::RANGES_SETS_PATH).and_return(true)
      allow(nm).to receive(:safe_write_to_file)
      allow(nm).to receive(:r).with("nft -f #{described_class::TABLE_PATH}")
      allow(nm).to receive(:r).with("nft -f #{described_class::RANGES_SETS_PATH}").and_raise("no such set")
      expect(logger).to receive(:warn).with(/stale ranges-sets cache/)
      expect { nm.apply }.not_to raise_error
    end
  end

  describe "#refresh" do
    let(:aws_provider) { NetworkMetering::Provider::Aws.new }
    let(:parts) do
      {
        "v4" => {"intra_region" => ["3.248.0.0/13"], "inter_region_t1" => ["13.124.0.0/16"], "excluded_svc" => ["52.218.0.0/17"]},
        "v6" => {"intra_region" => ["2600:1f00::/33"], "inter_region_t1" => ["2406:da14::/32"], "excluded_svc" => ["2001:4860::/32"]},
      }
    end
    let(:refresh_config) do
      base_config.merge("rules" => base_config["rules"] + [
        {"id" => "excluded_svc", "priority" => 40, "label" => "excluded", "source" => "provider"},
        {"id" => "intra_region", "priority" => 50, "label" => "intra_region", "source" => "provider"},
        {"id" => "inter_region_t1", "priority" => 61, "label" => "inter_region_t1", "source" => "provider"},
      ])
    end
    let(:staging_path) { "#{described_class::RANGES_SETS_PATH}.new" }

    before do
      allow(nm).to receive(:load_config).and_return(refresh_config)
      allow(described_class).to receive(:provider_for).with("aws").and_return(aws_provider)
      allow(aws_provider).to receive_messages(fetch_ranges: {}, classify_ranges: parts)
    end

    it "writes staging file, applies nft, then renames to canonical" do
      expect(nm).to receive(:safe_write_to_file) do |path, _|
        expect(path).to eq(staging_path)
      end
      expect(nm).to receive(:r).with("nft -f #{staging_path}")
      expect(File).to receive(:rename).with(staging_path, described_class::RANGES_SETS_PATH)
      nm.refresh
    end

    it "raises on degenerate v4 partition" do
      allow(aws_provider).to receive(:classify_ranges).and_return({"v4" => {"intra_region" => [], "inter_region_t1" => [], "excluded_svc" => []}, "v6" => parts["v6"]})
      expect { nm.refresh }.to raise_error(/refusing to apply degenerate range sets \(v4/)
    end

    it "raises on degenerate v6 partition (all keys empty)" do
      allow(aws_provider).to receive(:classify_ranges).and_return({"v4" => parts["v4"], "v6" => {"intra_region" => [], "inter_region_t1" => [], "excluded_svc" => []}})
      expect { nm.refresh }.to raise_error(/refusing to apply degenerate range sets \(v6/)
    end

    it "raises when the feeder does not declare the rule ids the config requests" do
      short_feeder = Class.new do
        def self.provided_ids(_c) = ["excluded_svc"]
        def fetch_ranges = nil
        def classify_ranges(_r, _region, _c) = {"v4" => {}, "v6" => {}}
      end
      allow(described_class).to receive(:provider_for).with("aws").and_return(short_feeder.new)
      expect { nm.refresh }.to raise_error(/does not know how to populate/)
    end

    it "silently drops partition entries not declared as provider-source in config" do
      allow(aws_provider).to receive(:classify_ranges).and_return({
        "v4" => parts["v4"].merge("inter_region_t2" => ["10.0.0.0/8"]),
        "v6" => parts["v6"],
      })
      txn_seen = nil
      allow(nm).to receive(:safe_write_to_file) { |_, txn| txn_seen = txn }
      allow(nm).to receive(:r)
      allow(File).to receive(:rename)
      nm.refresh
      expect(txn_seen).not_to include("inter_region_t2")
    end

    it "iterates named CIDR sources alongside the main provider" do
      cp_feeder = Class.new do
        def self.provided_ids(_c)
          ["clickpipes"]
        end

        def fetch_ranges
          nil
        end

        def classify_ranges(_r, _region, _c)
          {"v4" => {"clickpipes" => ["54.184.252.4/32"]}, "v6" => {}}
        end
      end
      stub_const("NetworkMetering::CIDR_SOURCES", {"clickpipes" => cp_feeder})
      config_with_source = refresh_config.merge("rules" => refresh_config["rules"] + [
        {"id" => "clickpipes", "priority" => 25, "label" => "clickpipes", "source" => "clickpipes"},
      ])
      allow(nm).to receive(:load_config).and_return(config_with_source)

      txn_seen = nil
      allow(nm).to receive(:safe_write_to_file) { |_, txn| txn_seen = txn }
      allow(nm).to receive(:r)
      allow(File).to receive(:rename)
      nm.refresh
      expect(txn_seen).to include("add element inet pg_metering clickpipes_v4 { 54.184.252.4/32 }")
    end

    it "does NOT apply the degenerate-v4 guard to add-on feeders (only main provider)" do
      empty_feeder = Class.new do
        def self.provided_ids(_c)
          ["clickpipes"]
        end

        def fetch_ranges
          nil
        end

        def classify_ranges(_r, _region, _c)
          {"v4" => {"clickpipes" => []}, "v6" => {}}
        end
      end
      stub_const("NetworkMetering::CIDR_SOURCES", {"clickpipes" => empty_feeder})
      config_with_source = refresh_config.merge("rules" => refresh_config["rules"] + [
        {"id" => "clickpipes", "priority" => 25, "label" => "clickpipes", "source" => "clickpipes"},
      ])
      allow(nm).to receive(:load_config).and_return(config_with_source)

      allow(nm).to receive(:safe_write_to_file)
      allow(nm).to receive(:r)
      allow(File).to receive(:rename)
      expect { nm.refresh }.not_to raise_error
    end
  end

  describe "#export" do
    let(:nft_json) do
      {"nftables" => [
        {"counter" => {"family" => "inet", "name" => "internal_v4_in", "table" => "pg_metering", "packets" => 3, "bytes" => 400}},
        {"counter" => {"family" => "inet", "name" => "public_internet_v6_out", "table" => "pg_metering", "packets" => 2, "bytes" => 99}},
        {"counter" => {"family" => "inet", "name" => "inter_region_v4_in", "table" => "pg_metering", "packets" => 5, "bytes" => 200}},
      ]}.to_json
    end

    it "emits Prom lines with bucket/direction/ip_version labels derived from counter names" do
      expect(nm).to receive(:r).with("nft -j list counters table inet pg_metering").and_return(nft_json)
      allow(File).to receive(:exist?).with(described_class::RANGES_SETS_PATH).and_return(true)
      allow(File).to receive(:mtime).with(described_class::RANGES_SETS_PATH).and_return(Time.now - 42)

      written = nil
      expect(File).to receive(:write) { |_, content| written = content }
      expect(File).to receive(:rename)
      nm.export

      expect(written).to include('pg_net_bytes_total{bucket="internal",direction="ingress",ip_version="ipv4"} 400')
      expect(written).to include('pg_net_bytes_total{bucket="public_internet",direction="egress",ip_version="ipv6"} 99')
      expect(written).to include('pg_net_bytes_total{bucket="inter_region",direction="ingress",ip_version="ipv4"} 200')
    end

    it "skips counters whose name does not match the label_family_direction pattern" do
      mixed = {"nftables" => [
        {"counter" => {"name" => "internal_v4_in", "bytes" => 100}},
        {"counter" => {"name" => "unrelated_counter", "bytes" => 999}},
      ]}.to_json
      expect(nm).to receive(:r).with("nft -j list counters table inet pg_metering").and_return(mixed)
      allow(File).to receive(:exist?).with(described_class::RANGES_SETS_PATH).and_return(true)
      allow(File).to receive(:mtime).with(described_class::RANGES_SETS_PATH).and_return(Time.now - 1)
      written = nil
      expect(File).to receive(:write) { |_, content| written = content }
      expect(File).to receive(:rename)
      nm.export
      expect(written).to include("internal")
      expect(written).not_to include("unrelated_counter")
    end

    it "reports age=-1 when the ranges-sets cache file does not exist" do
      empty = {"nftables" => []}.to_json
      expect(nm).to receive(:r).with("nft -j list counters table inet pg_metering").and_return(empty)
      allow(File).to receive(:exist?).with(described_class::RANGES_SETS_PATH).and_return(false)
      written = nil
      expect(File).to receive(:write) { |_, content| written = content }
      expect(File).to receive(:rename)
      nm.export
      expect(written).to include("pg_net_ranges_sets_age_seconds -1")
    end
  end
end
