# frozen_string_literal: true

require_relative "../lib/leaseweb_networking_setup"
require "tmpdir"

RSpec.describe LeasewebNetworkingSetup do
  subject(:setup) { described_class.new("netplan-yaml") }

  describe "#run" do
    it "generates, installs, archives, then applies" do
      expect(setup).to receive(:generate).ordered
      expect(setup).to receive(:install).ordered
      expect(setup).to receive(:archive).ordered
      expect(setup).to receive(:apply).ordered

      setup.run
    end
  end

  describe "#generate" do
    it "generates the config under a staging root and clears it" do
      expect(FileUtils).to receive(:rm_rf).with("/var/tmp/leaseweb-netplan").twice
      expect(FileUtils).to receive(:mkdir_p).with("/var/tmp/leaseweb-netplan/etc/netplan", mode: 0o700)
      expect(File).to receive(:write).with("/var/tmp/leaseweb-netplan/etc/netplan/01-netcfg.yaml", "netplan-yaml")
      expect(FileUtils).to receive(:chmod).with(0o600, "/var/tmp/leaseweb-netplan/etc/netplan/01-netcfg.yaml")
      expect(setup).to receive(:r).with("netplan generate --root-dir /var/tmp/leaseweb-netplan")

      setup.send(:generate)
    end
  end

  describe "#install" do
    it "copies the config it displaces to a temp, renames it onto the archive suffix, then writes the new one in place" do
      expect(File).to receive(:exist?).with("/etc/netplan/01-netcfg.yaml").and_return(true)
      expect(File).to receive(:exist?).with("/etc/netplan/01-netcfg.yaml.ubicloud-orig").and_return(false)
      expect(FileUtils).to receive(:cp)
        .with("/etc/netplan/01-netcfg.yaml", "/etc/netplan/01-netcfg.yaml.ubicloud-orig.tmp", preserve: true).ordered
      expect(File).to receive(:rename)
        .with("/etc/netplan/01-netcfg.yaml.ubicloud-orig.tmp", "/etc/netplan/01-netcfg.yaml.ubicloud-orig").ordered
      expect(setup).to receive(:safe_write_to_file).with("/etc/netplan/01-netcfg.yaml", "netplan-yaml", perm: 0o600).ordered

      setup.send(:install)
    end

    it "writes the new config without a copy when there is nothing to displace" do
      expect(File).to receive(:exist?).with("/etc/netplan/01-netcfg.yaml").and_return(false)
      expect(FileUtils).not_to receive(:cp)
      expect(File).not_to receive(:rename)
      expect(setup).to receive(:safe_write_to_file).with("/etc/netplan/01-netcfg.yaml", "netplan-yaml", perm: 0o600)

      setup.send(:install)
    end
  end

  describe "#archive" do
    it "displaces the other configs but leaves 01-netcfg.yaml in place" do
      expect(Dir).to receive(:glob).with("/etc/netplan/*.yaml")
        .and_return(["/etc/netplan/01-netcfg.yaml", "/etc/netplan/50-cloud-init.yaml"])
      expect(File).to receive(:exist?).with("/etc/netplan/50-cloud-init.yaml.ubicloud-orig").and_return(false)
      expect(File).to receive(:rename)
        .with("/etc/netplan/50-cloud-init.yaml", "/etc/netplan/50-cloud-init.yaml.ubicloud-orig")

      setup.send(:archive)
    end
  end

  # The mock examples above pin the call sequence; these pin the on-disk
  # invariant the fix exists for by running install then archive against a real
  # directory: /etc/netplan never goes empty and the displaced configs survive.
  describe "install then archive against a real /etc/netplan" do
    before do
      @dir = Dir.mktmpdir
      @netplan_path = File.join(@dir, "01-netcfg.yaml")
      stub_const("LeasewebNetworkingSetup::NETPLAN_DIR", @dir)
      stub_const("LeasewebNetworkingSetup::NETPLAN_PATH", @netplan_path)
    end

    after do
      FileUtils.rm_rf(@dir)
    end

    it "keeps a config live through install and archive, and keeps the stock one" do
      stock = File.join(@dir, "50-cloud-init.yaml")
      File.write(stock, "stock")

      setup.send(:install)
      expect(File.read(@netplan_path)).to eq("netplan-yaml")
      expect(File.stat(@netplan_path).mode & 0o777).to eq(0o600)
      expect(Dir.glob(File.join(@dir, "*.yaml")).sort).to eq([@netplan_path, stock].sort)

      setup.send(:archive)
      expect(Dir.glob(File.join(@dir, "*.yaml"))).to eq([@netplan_path])
      expect(File.read("#{stock}.ubicloud-orig")).to eq("stock")
    end

    it "preserves the config it displaces and rotates the next run behind it" do
      File.write(@netplan_path, "old-ours")

      setup.send(:install)
      expect(File.read(@netplan_path)).to eq("netplan-yaml")
      expect(File.read("#{@netplan_path}.ubicloud-orig")).to eq("old-ours")

      described_class.new("newer-yaml").send(:install)
      expect(File.read(@netplan_path)).to eq("newer-yaml")
      expect(File.read("#{@netplan_path}.ubicloud-orig")).to eq("old-ours")
      expect(File.read("#{@netplan_path}.ubicloud-disabled")).to eq("netplan-yaml")
    end
  end

  describe "#apply" do
    it "generates and applies the live config" do
      expect(setup).to receive(:r).with("netplan generate").ordered
      expect(setup).to receive(:r).with("netplan apply").ordered

      setup.send(:apply)
    end
  end

  describe "#archive_target" do
    it "settles the first config displaced at a name in .ubicloud-orig" do
      expect(File).to receive(:exist?).with("/etc/netplan/50-cloud-init.yaml.ubicloud-orig").and_return(false)

      expect(setup.send(:archive_target, "/etc/netplan/50-cloud-init.yaml"))
        .to eq("/etc/netplan/50-cloud-init.yaml.ubicloud-orig")
    end

    it "rotates through .ubicloud-disabled once .ubicloud-orig is taken" do
      expect(File).to receive(:exist?).with("/etc/netplan/01-netcfg.yaml.ubicloud-orig").and_return(true)

      expect(setup.send(:archive_target, "/etc/netplan/01-netcfg.yaml"))
        .to eq("/etc/netplan/01-netcfg.yaml.ubicloud-disabled")
    end
  end
end
