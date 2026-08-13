# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe StorageDevice do
  describe ".convert_device_name_to_device_id" do
    it "returns the wwn id for SSD disks" do
      sshable = Sshable.create(host: "test.localhost", raw_private_key_1: SshKey.generate.keypair)
      expect(sshable).to receive(:_cmd).with("ls -l /dev/disk/by-id/ | grep sda\\$ | grep 'wwn-' | sed -E 's/.*(wwn[^ ]*).*/\\1/'").and_return("wwn-random-id")
      expect(described_class.convert_device_name_to_device_id(sshable, "sda")).to eq("wwn-random-id")
    end

    it "returns the nvme-eui id for NVMe disks" do
      sshable = Sshable.create(host: "test.localhost", raw_private_key_1: SshKey.generate.keypair)
      expect(sshable).to receive(:_cmd).with("ls -l /dev/disk/by-id/ | grep nvme0n1\\$ | grep 'nvme-eui' | sed -E 's/.*(nvme-eui[^ ]*).*/\\1/'").and_return("nvme-eui.random-id")
      expect(described_class.convert_device_name_to_device_id(sshable, "nvme0n1")).to eq("nvme-eui.random-id")
    end

    it "returns the device_name unchanged for other disks" do
      sshable = Sshable.create(host: "test.localhost", raw_private_key_1: SshKey.generate.keypair)
      expect(described_class.convert_device_name_to_device_id(sshable, "qwer")).to eq("qwer")
    end
  end

  describe "#path" do
    it "returns /var/storage/ for DEFAULT device" do
      expect(described_class.new(name: "DEFAULT").path).to eq("/var/storage/")
    end

    it "returns /var/storage/devices/<name> for non-DEFAULT device" do
      expect(described_class.new(name: "disk1").path).to eq("/var/storage/devices/disk1")
    end
  end
end
