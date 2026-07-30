# frozen_string_literal: true

require "spec_helper"
require "network_metering_methods"

class NetworkMeteringMethodsTestClass
  include NetworkMeteringMethods

  attr_accessor :vm, :resource
end

RSpec.describe NetworkMeteringMethods do
  let(:instance) { NetworkMeteringMethodsTestClass.new }

  describe "#split_ips_by_version" do
    it "groups v4 and v6 CIDRs" do
      result = instance.split_ips_by_version(["10.0.0.0/8", "2600:1f14::/32", "192.168.0.1", "fc00::/7"])
      expect(result["v4"]).to eq(["10.0.0.0/8", "192.168.0.1"])
      expect(result["v6"]).to eq(["2600:1f14::/32", "fc00::/7"])
    end

    it "returns empty arrays for empty input" do
      expect(instance.split_ips_by_version([])).to eq({"v4" => [], "v6" => []})
    end

    it "raises for garbage entries" do
      expect { instance.split_ips_by_version(["not-an-ip"]) }.to raise_error(/invalid IP entry/)
    end
  end

  describe "#base_rules" do
    before { allow(Config).to receive(:control_plane_outbound_cidrs).and_return(["0.0.0.0/0", "::/0"]) }

    it "returns internal, control_plane, provider-source rules, and public_internet catchall" do
      ids = instance.base_rules.map { |r| r["id"] }
      expect(ids).to contain_exactly("internal", "control_plane", "excluded_svc", "intra_region", "inter_region_t1", "public_internet")
    end

    it "marks intra/inter/excluded rules as provider-source (populated by daily refresh)" do
      provider_ids = instance.base_rules.select { |r| r["source"] == "provider" }.map { |r| r["id"] }
      expect(provider_ids).to contain_exactly("excluded_svc", "intra_region", "inter_region_t1")
    end

    it "declares public_internet as catchall (no cidrs)" do
      catchall = instance.base_rules.find { |r| r["id"] == "public_internet" }
      expect(catchall["type"]).to eq("catchall")
      expect(catchall).not_to have_key("cidrs")
    end

    it "seeds internal_v4 with RFC1918 + link-local" do
      internal = instance.base_rules.find { |r| r["id"] == "internal" }
      expect(internal["cidrs"]["v4"]).to include("10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "169.254.0.0/16")
    end

    it "seeds internal_v6 with ULA + link-local" do
      internal = instance.base_rules.find { |r| r["id"] == "internal" }
      expect(internal["cidrs"]["v6"]).to include("fc00::/7", "fe80::/10")
    end
  end

  describe "#control_plane_cidrs" do
    it "returns empty v4/v6 lists when Config only has the default supernets" do
      allow(Config).to receive(:control_plane_outbound_cidrs).and_return(["0.0.0.0/0", "::/0"])
      expect(instance.control_plane_cidrs).to eq({"v4" => [], "v6" => []})
    end

    it "keeps operator-supplied cidrs and drops supernets" do
      allow(Config).to receive(:control_plane_outbound_cidrs).and_return(["0.0.0.0/0", "3.143.188.173/32", "2600:1f14::/56", "::/0"])
      expect(instance.control_plane_cidrs).to eq({"v4" => ["3.143.188.173/32"], "v6" => ["2600:1f14::/56"]})
    end
  end

  describe "#network_metering_config" do
    let(:location_double) { double(name: "us-east-1") }
    let(:resource_double) { double(location: location_double) }

    before do
      instance.resource = resource_double
      allow(Config).to receive(:control_plane_outbound_cidrs).and_return(["0.0.0.0/0", "::/0"])
    end

    it "composes version, region, provider, sorted rules, empty provider_config" do
      cfg = instance.network_metering_config("aws")
      expect(cfg["version"]).to eq(1)
      expect(cfg["region"]).to eq("us-east-1")
      expect(cfg["provider"]).to eq("aws")
      priorities = cfg["rules"].map { |r| r["priority"] }
      expect(priorities).to eq(priorities.sort)
      expect(cfg["provider_config"]).to eq({})
    end
  end

  describe "#render_network_metering_units" do
    let(:units) { instance.render_network_metering_units }

    it "renders 5 unit files" do
      expect(units.keys).to contain_exactly(
        "/etc/systemd/system/pg-metering.service",
        "/etc/systemd/system/pg-metering-export.service",
        "/etc/systemd/system/pg-metering-export.timer",
        "/etc/systemd/system/pg-metering-refresh.service",
        "/etc/systemd/system/pg-metering-refresh.timer",
      )
    end

    it "pg-metering.service invokes apply-metering-config" do
      expect(units["/etc/systemd/system/pg-metering.service"]).to include("ExecStart=/home/ubi/postgres/bin/apply-metering-config")
    end

    it "export timer fires every minute" do
      expect(units["/etc/systemd/system/pg-metering-export.timer"]).to include("OnUnitActiveSec=60s")
    end

    it "refresh timer is daily with random delay + persistent catch-up" do
      body = units["/etc/systemd/system/pg-metering-refresh.timer"]
      expect(body).to include("OnCalendar=daily")
      expect(body).to include("RandomizedDelaySec=1h")
      expect(body).to include("Persistent=true")
    end
  end
end
