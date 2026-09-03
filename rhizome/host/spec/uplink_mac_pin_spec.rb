# frozen_string_literal: true

require_relative "../lib/uplink_mac_pin"
require "tmpdir"

RSpec.describe UplinkMacPin do
  subject(:pin) { described_class.new }

  let(:netplan_dir) { Dir.mktmpdir }
  let(:staging_dir) { "/var/tmp/uplink-mac-pin" }
  let(:path) { File.join(netplan_dir, "01-netcfg.yaml") }

  let(:named_netplan) do
    <<~YAML
      network:
        version: 2
        renderer: networkd
        ethernets:
          enp2s0:
            addresses:
              - 157.90.0.37/32
              - 2a01:4f8:2b02:699::2/64
            routes:
              - on-link: true
                to: 0.0.0.0/0
                via: 157.90.0.1
              - to: default
                via: fe80::1
    YAML
  end

  before do
    allow(Dir).to receive(:glob).and_call_original
    allow(Dir).to receive(:glob).with("/etc/netplan/*.yaml") { Dir.children(netplan_dir).filter_map { |name| File.join(netplan_dir, name) if name.end_with?(".yaml") } }
    File.write(path, named_netplan)
  end

  after do
    FileUtils.rm_rf(netplan_dir)
    FileUtils.rm_rf(staging_dir)
  end

  # Stands in for netplan generate: renders each ethernet's addresses under a
  # [Match] keyed on however that ethernet is selected, which is exactly the
  # part verify is required to ignore.
  def stub_netplan_generate(divergent: nil)
    allow(pin).to receive(:_run_command).with("netplan", "generate", "--root-dir", anything) do |*args|
      root = args.last
      out = File.join(root, "run/systemd/network")
      FileUtils.mkdir_p(out)
      doc = YAML.safe_load_file(File.join(root, "etc/netplan/01-netcfg.yaml"), permitted_classes: [Symbol])
      doc.dig("network", "ethernets").each do |id, conf|
        addresses = conf["addresses"].to_a
        addresses += [divergent] if divergent && File.basename(root) == "after"
        File.write(File.join(out, "10-netplan-#{id}.network"),
          "[Match]\nName=#{id}\n\n[Network]\n" + addresses.map { |address| "Address=#{address}\n" }.join)
      end
      ""
    end
  end

  def stub_uplink(dev: "enp2s0", mac: "98:b7:85:00:99:9a")
    allow(pin).to receive(:_run_command).with("ip", "-j", "route", "show", "default")
      .and_return(JSON.generate([{dst: "default", gateway: "157.90.0.1", dev: dev}]))
    allow(pin).to receive(:_run_command).with("ethtool", "-P", dev)
      .and_return("Permanent address: #{mac}\n")
  end

  describe "#run" do
    it "rewrites the named ethernet to select the uplink by its permanent mac" do
      stub_uplink
      stub_netplan_generate

      expect(pin.run).to eq "pinned enp2s0 to 98:b7:85:00:99:9a in #{path}"

      ethernets = YAML.safe_load_file(path, permitted_classes: [Symbol]).dig("network", "ethernets")
      expect(ethernets.keys).to eq ["uplink"]
      expect(ethernets["uplink"]["match"]).to eq("macaddress" => "98:b7:85:00:99:9a")
    end

    it "keeps every address and route the entry carried" do
      stub_uplink
      stub_netplan_generate
      before = YAML.safe_load_file(path, permitted_classes: [Symbol]).dig("network", "ethernets", "enp2s0")

      pin.run

      after = YAML.safe_load_file(path, permitted_classes: [Symbol]).dig("network", "ethernets", "uplink")
      expect(after.except("match")).to eq before
    end

    it "writes an unquoted ipv6 default route back unchanged" do
      stub_uplink
      stub_netplan_generate

      pin.run

      expect(File.read(path)).to include("via: fe80::1")
    end

    it "keeps the displaced config alongside the rewritten one" do
      stub_uplink
      stub_netplan_generate

      pin.run

      expect(File.read(path + ".ubicloud-orig")).to eq named_netplan
    end

    it "leaves an entry that already matches on something alone" do
      File.write(path, named_netplan.sub("    enp2s0:\n", "    enp2s0:\n      match:\n        macaddress: 98:b7:85:00:99:9a\n"))
      stub_uplink

      expect(pin.run).to eq "netplan does not select enp2s0 by name, nothing to pin"
      expect(File).not_to exist(path + ".ubicloud-orig")
    end

    it "ignores files that configure no ethernets, and entries that are not mappings" do
      File.write(File.join(netplan_dir, "00-empty.yaml"), "network:\n  version: 2\n")
      File.write(File.join(netplan_dir, "00-blank-entry.yaml"), "network:\n  version: 2\n  ethernets:\n    enp2s0:\n")
      stub_uplink
      stub_netplan_generate

      expect(pin.run).to eq "pinned enp2s0 to 98:b7:85:00:99:9a in #{path}"
    end

    it "refuses to write a rewrite that would change what netplan generates" do
      stub_uplink
      stub_netplan_generate(divergent: "10.0.0.1/32")

      expect { pin.run }.to raise_error RuntimeError, "pinning #{path} would change the generated network configuration"
      expect(YAML.safe_load_file(path, permitted_classes: [Symbol]).dig("network", "ethernets").keys).to eq ["enp2s0"]
    end

    it "clears the staging root even when verification fails" do
      stub_uplink
      stub_netplan_generate(divergent: "10.0.0.1/32")

      expect { pin.run }.to raise_error RuntimeError
      expect(File).not_to exist(staging_dir)
    end

    it "fails when the host has no default route" do
      allow(pin).to receive(:_run_command).with("ip", "-j", "route", "show", "default").and_return("[]")

      expect { pin.run }.to raise_error RuntimeError, "no default route to identify the uplink interface"
    end

    it "fails when netplan already has an ethernet named uplink" do
      File.write(File.join(netplan_dir, "02-extra.yaml"), "network:\n  version: 2\n  ethernets:\n    uplink:\n      dhcp4: false\n")
      stub_uplink

      expect { pin.run }.to raise_error RuntimeError, "netplan already has an ethernet named uplink"
    end
  end

  describe "#permanent_mac" do
    before { stub_uplink }

    it "falls back to the sysfs address when ethtool reports none" do
      allow(pin).to receive(:_run_command).with("ethtool", "-P", "enp2s0").and_return("Permanent address: not set\n")
      allow(File).to receive(:read).with("/sys/class/net/enp2s0/address").and_return("98:b7:85:00:99:9a\n")

      expect(pin.send(:permanent_mac, "enp2s0")).to eq "98:b7:85:00:99:9a"
    end

    it "falls back to the sysfs address when ethtool reports all zeroes" do
      allow(pin).to receive(:_run_command).with("ethtool", "-P", "enp2s0").and_return("Permanent address: 00:00:00:00:00:00\n")
      allow(File).to receive(:read).with("/sys/class/net/enp2s0/address").and_return("98:b7:85:00:99:9a\n")

      expect(pin.send(:permanent_mac, "enp2s0")).to eq "98:b7:85:00:99:9a"
    end

    it "fails when neither source yields a mac" do
      allow(pin).to receive(:_run_command).with("ethtool", "-P", "enp2s0").and_return("")
      allow(File).to receive(:read).with("/sys/class/net/enp2s0/address").and_return("\n")

      expect { pin.send(:permanent_mac, "enp2s0") }.to raise_error RuntimeError, "no permanent mac for enp2s0"
    end
  end

  describe "#archive" do
    it "keeps the first config it displaces and leaves it there on a rerun" do
      pin.send(:archive, path)
      File.write(path, "changed")
      pin.send(:archive, path)

      expect(File.read(path + ".ubicloud-orig")).to eq named_netplan
    end
  end
end
