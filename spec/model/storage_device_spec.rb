# frozen_string_literal: true

require_relative "../../lib/system_parser"
require "rspec"

RSpec.describe StorageDevice do
  describe "#migrate_device_name_to_device_id" do
    context "when finding the disk id from device_name for SSD disks" do
      it "changes the unix_device_list to the device id and saves changes" do
        sa = Sshable.create_with_id(host: "test.localhost", raw_private_key_1: SshKey.generate.keypair)
        vmh = VmHost.create(location: "test-location") { _1.id = sa.id }
        storage_device = described_class.create_with_id(vm_host_id: vmh.id, name: "DEFAULT", total_storage_gib: 100, available_storage_gib: 100, unix_device_list: ["sda"])

        expect(storage_device.vm_host.sshable).to receive(:cmd).with("ls -l /dev/disk/by-id/ | grep 'sda$' | grep 'wwn-' | sed -E 's/.*(wwn[^ ]*).*/\\1/'").and_return("wwn-random-id")
        expect(storage_device).to receive(:save_changes)
        storage_device.migrate_device_name_to_device_id
        expect(storage_device.unix_device_list).to(eq(["wwn-random-id"]))
      end
    end

    context "when finding the disk id from device_name for NVMe disks" do
      it "changes the unix_device_list to the device id and saves changes" do
        sa = Sshable.create_with_id(host: "test.localhost", raw_private_key_1: SshKey.generate.keypair)
        vmh = VmHost.create(location: "test-location") { _1.id = sa.id }
        storage_device = described_class.create_with_id(vm_host_id: vmh.id, name: "DEFAULT", total_storage_gib: 100, available_storage_gib: 100, unix_device_list: ["nvme0n1"])

        expect(storage_device.vm_host.sshable).to receive(:cmd).with("ls -l /dev/disk/by-id/ | grep 'nvme0n1$' | grep 'nvme-eui' | sed -E 's/.*(nvme-eui[^ ]*).*/\\1/'").and_return("nvme-eui.random-id")
        expect(storage_device).to receive(:save_changes)
        storage_device.migrate_device_name_to_device_id
        expect(storage_device.unix_device_list).to(eq(["nvme-eui.random-id"]))
      end
    end

    context "when converting device name to device id on non ssd or nvme disks" do
      it "returns the device_name unchanged" do
        sshable = Sshable.create_with_id(host: "test.localhost", raw_private_key_1: SshKey.generate.keypair)
        expect(described_class.convert_device_name_to_device_id(sshable, "qwer")).to equal("qwer")
      end
    end
  end
end
