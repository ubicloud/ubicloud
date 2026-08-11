# frozen_string_literal: true

require "json"
require "logger"
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
        {"id" => "intra_region", "priority" => 50, "label" => "intra_region",
         "cidrs" => {"v4" => ["3.248.0.0/13"], "v6" => []}},
        {"id" => "public_internet", "priority" => 999, "label" => "public_internet", "type" => "catchall"},
      ],
    }
  end

  describe "#load_config" do
    it "parses the config file" do
      expect(File).to receive(:read).with(described_class::CONFIG_PATH).and_return(JSON.generate(base_config))
      expect(nm.load_config).to include("version" => 1)
    end

    it "raises on unsupported version" do
      expect(File).to receive(:read).with(described_class::CONFIG_PATH).and_return(JSON.generate(base_config.merge("version" => 2)))
      expect { nm.load_config }.to raise_error(/unsupported config version 2/)
    end
  end

  describe "#render_table" do
    it "renders the full nftables table for a minimal 3-rule config" do
      rules = [
        {"id" => "internal", "priority" => 10, "label" => "internal",
         "cidrs" => {"v4" => ["10.0.0.0/8"], "v6" => ["fc00::/7"]}},
        {"id" => "public_internet", "priority" => 999, "label" => "public_internet", "type" => "catchall"},
      ]
      expect(nm.render_table(rules)).to eq(<<~TABLE)
        table inet pg_metering;
        delete table inet pg_metering;
        table inet pg_metering {
        set internal_v4 {
          type ipv4_addr
          flags interval
          auto-merge
          elements = { 10.0.0.0/8 }
        }

        set internal_v6 {
          type ipv6_addr
          flags interval
          auto-merge
          elements = { fc00::/7 }
        }


        counter internal_v4_in {}
        counter internal_v4_out {}
        counter internal_v6_in {}
        counter internal_v6_out {}
        counter public_internet_v4_in {}
        counter public_internet_v4_out {}
        counter public_internet_v6_in {}
        counter public_internet_v6_out {}

        chain ingress {
          type filter hook input priority filter; policy accept;
          iifname "lo" accept
          meta l4proto != tcp accept
          meta nfproto ipv4 goto ingress_v4
          meta nfproto ipv6 goto ingress_v6
        }


        chain egress {
          type filter hook output priority filter; policy accept;
          oifname "lo" accept
          meta l4proto != tcp accept
          meta nfproto ipv4 goto egress_v4
          meta nfproto ipv6 goto egress_v6
        }


        chain ingress_v4 {
          ip saddr @internal_v4 counter name internal_v4_in accept
          counter name public_internet_v4_in
        }

        chain egress_v4 {
          ip daddr @internal_v4 counter name internal_v4_out accept
          counter name public_internet_v4_out
        }

        chain ingress_v6 {
          ip6 saddr @internal_v6 counter name internal_v6_in accept
          counter name public_internet_v6_in
        }

        chain egress_v6 {
          ip6 daddr @internal_v6 counter name internal_v6_out accept
          counter name public_internet_v6_out
        }

        }
      TABLE
    end

    it "renders empty sets as single-line declarations" do
      table = nm.render_table(base_config["rules"])
      expect(table).to include("set intra_region_v6 { type ipv6_addr; flags interval; auto-merge; }")
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
  end

  describe "#apply" do
    let(:kernel_check_cmd) { "nft list table inet pg_metering > /dev/null 2>&1 && echo YES || echo NO" }
    let(:nft_apply_cmd) { "nft -f #{described_class::TABLE_PATH}" }

    before do
      allow(nm).to receive(:load_config).and_return(base_config)
      allow(nm).to receive(:install_units)
    end

    it "renders and applies when hash differs" do
      expect(File).to receive(:exist?).at_least(:once).and_return(false)
      expect(nm).to receive(:safe_write_to_file).with(described_class::TABLE_PATH, anything)
      expect(nm).to receive(:_run_command).with(nft_apply_cmd)
      expect(nm).to receive(:safe_write_to_file).with(described_class::SCHEMA_HASH_PATH, /\A[0-9a-f]{64}\z/)
      nm.apply
    end

    it "skips when hash matches and kernel table loaded" do
      cur_hash = Digest::SHA256.hexdigest(nm.render_table(base_config["rules"]))
      expect(File).to receive(:exist?).at_least(:once).and_return(true)
      expect(File).to receive(:read).with(described_class::SCHEMA_HASH_PATH).and_return(cur_hash)
      expect(nm).to receive(:_run_command).with(kernel_check_cmd).and_return("YES\n")
      expect(nm).not_to receive(:safe_write_to_file)
      expect(nm).not_to receive(:_run_command).with(nft_apply_cmd)
      nm.apply
    end

    it "reloads when kernel table missing despite matching hash" do
      cur_hash = Digest::SHA256.hexdigest(nm.render_table(base_config["rules"]))
      expect(File).to receive(:exist?).at_least(:once).and_return(true)
      expect(File).to receive(:read).with(described_class::SCHEMA_HASH_PATH).and_return(cur_hash)
      expect(nm).to receive(:_run_command).with(kernel_check_cmd).and_return("NO\n")
      expect(nm).to receive(:safe_write_to_file).with(described_class::TABLE_PATH, anything)
      expect(nm).to receive(:_run_command).with(nft_apply_cmd)
      expect(nm).to receive(:safe_write_to_file).with(described_class::SCHEMA_HASH_PATH, /\A[0-9a-f]{64}\z/)
      nm.apply
    end
  end

  describe "#install_units" do
    let(:src_dir) { described_class::SYSTEMD_SRC_DIR }
    let(:dst_dir) { described_class::SYSTEMD_DST_DIR }

    it "no-ops when all destination unit files match the rhizome copies" do
      described_class::UNIT_FILES.each do |name|
        expect(File).to receive(:exist?).with("#{dst_dir}/#{name}").and_return(true)
        expect(File).to receive(:read).with("#{src_dir}/#{name}").and_return("same")
        expect(File).to receive(:read).with("#{dst_dir}/#{name}").and_return("same")
      end
      expect(nm).not_to receive(:_run_command)
      nm.install_units
    end

    it "installs missing unit files, reloads daemon, and enables the pair" do
      described_class::UNIT_FILES.each do |name|
        expect(File).to receive(:exist?).with("#{dst_dir}/#{name}").and_return(false)
      end
      described_class::UNIT_FILES.each do |name|
        expect(nm).to receive(:_run_command).with("sudo install -m 0644 #{src_dir}/#{name} #{dst_dir}/#{name}")
      end
      expect(nm).to receive(:_run_command).with("sudo systemctl daemon-reload")
      expect(nm).to receive(:_run_command).with("sudo systemctl enable pg-metering.service")
      expect(nm).to receive(:_run_command).with("sudo systemctl enable --now pg-metering-export.timer")
      nm.install_units
    end
  end

  describe "#export" do
    let(:nft_json) do
      {"nftables" => [
        {"counter" => {"name" => "internal_v4_in", "bytes" => 400}},
        {"counter" => {"name" => "public_internet_v6_out", "bytes" => 99}},
        {"counter" => {"name" => "unrelated_counter", "bytes" => 999}},
      ]}.to_json
    end

    it "emits Prom lines with bucket/direction/ip_version labels" do
      expect(nm).to receive(:_run_command).with("nft -j list counters table inet pg_metering").and_return(nft_json)
      written = nil
      expect(nm).to receive(:safe_write_to_file).with(described_class::PROM_PATH, anything) { |_, content| written = content }
      nm.export
      expect(written).to include('pg_net_bytes_total{bucket="internal",direction="ingress",ip_version="ipv4"} 400')
      expect(written).to include('pg_net_bytes_total{bucket="public_internet",direction="egress",ip_version="ipv6"} 99')
      expect(written).not_to include("unrelated_counter")
    end
  end
end
