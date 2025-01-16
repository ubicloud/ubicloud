# frozen_string_literal: true

require_relative "../../lib/system_parser"
require "rspec"

RSpec.describe StorageDevice do
  describe "#set_underlying_unix_devices" do
    context "when the device is not a RAID (non-RAID disk)" do
      it "sets unix_device_list to the device name and saves changes" do
        sa = Sshable.create_with_id(host: "test.localhost", raw_private_key_1: SshKey.generate.keypair)
        vmh = VmHost.create(location: "test-location") { _1.id = sa.id }
        storage_device = described_class.create_with_id(vm_host_id: vmh.id, name: "DEFAULT", total_storage_gib: 100, available_storage_gib: 100)

        allow(storage_device.vm_host.sshable).to receive(:cmd).with(SystemParser.df_command("/var/storage")).and_return(<<~EOS)
          Filesystem                Mounted on    1B-blocks        Avail
          /dev/sda                  /            452564664320     381456842752
        EOS

        expect(storage_device).to receive(:save_changes)
        storage_device.set_underlying_unix_devices
        expect(storage_device.unix_device_list).to(eq(["sda"]))
      end
    end

    context "when the device is a non-RAID disk and is not the default disk" do
      it "sets unix_device_list to the device name and saves changes" do
        sa = Sshable.create_with_id(host: "test.localhost", raw_private_key_1: SshKey.generate.keypair)
        vmh = VmHost.create(location: "test-location") { _1.id = sa.id }
        storage_device = described_class.create_with_id(vm_host_id: vmh.id, name: "sdc", total_storage_gib: 100, available_storage_gib: 100)

        allow(storage_device.vm_host.sshable).to receive(:cmd).with(SystemParser.df_command("/var/storage/devices/sdc")).and_return(<<~EOS)
          Filesystem                Mounted on    1B-blocks        Avail
          /dev/sdc                  /            452564664320     381456842752
        EOS

        expect(storage_device).to receive(:save_changes)
        storage_device.set_underlying_unix_devices
        expect(storage_device.unix_device_list).to(eq(["sdc"]))
      end
    end

    context "when the device is a RAID (RAID disk)" do
      it "extracts RAID component devices and sets them as unix_devices" do
        sa = Sshable.create_with_id(host: "test.localhost", raw_private_key_1: SshKey.generate.keypair)
        vmh = VmHost.create(location: "test-location") { _1.id = sa.id }
        storage_device = described_class.create_with_id(vm_host_id: vmh.id, name: "DEFAULT", total_storage_gib: 100, available_storage_gib: 100)

        allow(storage_device.vm_host.sshable).to receive(:cmd).with(SystemParser.df_command("/var/storage")).and_return(<<~EOS)
          Filesystem                Mounted on    1B-blocks        Avail
          /dev/md0                  /            452564664320     381456842752
        EOS

        allow(storage_device.vm_host.sshable).to receive(:cmd).with("cat /proc/mdstat").and_return(<<~EOS)
          Personalities : [raid1]
          md0 : active raid1 nvme1n1p3[1] nvme0n1p3[0]
                465370432 blocks super 1.2 [2/2] [UU]
                bitmap: 3/4 pages [12KB], 65536KB chunk

          unused devices: <none>
        EOS

        expect(storage_device).to receive(:save_changes)
        storage_device.set_underlying_unix_devices
        expect(storage_device.unix_device_list).to eq(["nvme1n1", "nvme0n1"])
      end
    end

    context "when there is no mount point or device info available" do
      it "does not set unix_devices and raises an error if df output is invalid" do
        sa = Sshable.create_with_id(host: "test.localhost", raw_private_key_1: SshKey.generate.keypair)
        vmh = VmHost.create(location: "test-location") { _1.id = sa.id }
        storage_device = described_class.create_with_id(vm_host_id: vmh.id, name: "DEFAULT", total_storage_gib: 100, available_storage_gib: 100)

        allow(storage_device.vm_host.sshable).to receive(:cmd).with(SystemParser.df_command("/var/storage")).and_return("Invalid output")

        expect {
          storage_device.set_underlying_unix_devices
        }.to raise_error(RuntimeError, "BUG: df header parse failed")
      end
    end
  end
end
