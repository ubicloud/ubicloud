# frozen_string_literal: true

require_relative "../lib/storage_disk_formatter"

RSpec.describe StorageDiskFormatter do
  subject(:formatter) { described_class.new }

  describe "#boot_disk" do
    it "returns the parent disk of the /boot partition" do
      expect(formatter).to receive(:r).with("findmnt -n -o SOURCE /boot").and_return("/dev/nvme0n1p2\n")
      expect(formatter).to receive(:r).with("lsblk -no PKNAME /dev/nvme0n1p2").and_return("nvme0n1\n")
      expect(formatter.boot_disk).to eq("nvme0n1")
    end

    it "fails if the boot disk cannot be determined" do
      expect(formatter).to receive(:r).with("findmnt -n -o SOURCE /boot").and_return("/dev/nvme0n1p2\n")
      expect(formatter).to receive(:r).with("lsblk -no PKNAME /dev/nvme0n1p2").and_return("\n")
      expect { formatter.boot_disk }.to raise_error RuntimeError, "could not determine the boot disk"
    end
  end

  describe "#data_disks" do
    it "returns all disks except the boot disk, sorted by name" do
      expect(formatter).to receive(:boot_disk).and_return("nvme0n1")
      expect(formatter).to receive(:r).with("lsblk -ndo NAME,TYPE").and_return(<<~OUTPUT)
        nvme2n1 disk
        nvme0n1 disk
        loop0 loop
        nvme1n1 disk
      OUTPUT
      expect(formatter.data_disks).to eq(["/dev/nvme1n1", "/dev/nvme2n1"])
    end
  end

  describe "#format" do
    it "formats each data disk and mounts all of them" do
      expect(formatter).to receive(:data_disks).and_return(["/dev/nvme1n1", "/dev/nvme2n1"])
      expect(formatter).to receive(:format_disk).with("/dev/nvme1n1", "/var/storage/devices/disk1")
      expect(formatter).to receive(:format_disk).with("/dev/nvme2n1", "/var/storage/devices/disk2")
      expect(formatter).to receive(:r).with("mount -a")
      formatter.format
    end
  end

  describe "#format_disk" do
    it "skips disks already recorded in fstab" do
      expect(File).to receive(:read).with("/etc/fstab").and_return("UUID=123-abc /var/storage/devices/disk1 ext4 defaults 0 2\n")
      expect(formatter).not_to receive(:r)
      formatter.format_disk("/dev/nvme1n1", "/var/storage/devices/disk1")
    end

    it "skips a disk that is already mounted" do
      expect(File).to receive(:read).with("/etc/fstab").and_return("UUID=y / ext4 defaults 0 1\n")
      expect(formatter).to receive(:r).with("lsblk -no MOUNTPOINTS /dev/nvme1n1").and_return("/var/foo\n")
      expect(formatter).not_to receive(:r).with("wipefs -fa /dev/nvme1n1")
      formatter.format_disk("/dev/nvme1n1", "/var/storage/devices/disk1")
    end

    it "wipes, formats, mounts the disk and persists it in fstab" do
      expect(File).to receive(:read).with("/etc/fstab").and_return("UUID=y / ext4 defaults 0 1\n")
      expect(formatter).to receive(:r).with("lsblk -no MOUNTPOINTS /dev/nvme1n1").and_return("\n")
      expect(formatter).to receive(:r).with("wipefs -fa /dev/nvme1n1")
      expect(formatter).to receive(:r).with("mkfs.ext4 /dev/nvme1n1")
      expect(FileUtils).to receive(:mkdir_p).with("/var/storage/devices/disk1")
      expect(formatter).to receive(:r).with("mount /dev/nvme1n1 /var/storage/devices/disk1")
      expect(formatter).to receive(:r).with("blkid -s UUID -o value /dev/nvme1n1").and_return("123-abc\n")

      fstab_file = instance_double(File)
      expect(fstab_file).to receive(:flock).with(File::LOCK_EX)
      expect(fstab_file).to receive(:read).and_return("UUID=y / ext4 defaults 0 1\n")
      expect(File).to receive(:open).with("/etc/fstab", File::RDONLY).and_yield(fstab_file)
      expect(formatter).to receive(:safe_write_to_file).with("/etc/fstab", "UUID=y / ext4 defaults 0 1\n# /dev/nvme1n1\nUUID=123-abc /var/storage/devices/disk1 ext4 defaults 0 2\n")

      formatter.format_disk("/dev/nvme1n1", "/var/storage/devices/disk1")
    end
  end
end
