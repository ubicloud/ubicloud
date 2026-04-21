# frozen_string_literal: true

require_relative "../lib/crypt_swap_setup"

RSpec.describe CryptSwapSetup do
  describe ".run" do
    let(:fstab) {
      <<~FSTAB
            proc /proc proc defaults 0 0
            # efi-boot-partition
            UUID=44F3-D390 /boot/efi vfat umask=0077 0 1
            # /dev/nvme0n1p2
            UUID=4c4fe278-d132-4136-8073-b1242eacf5eb none swap sw 0 0
            # /dev/nvme0n1p3
            UUID=5d7f632b-2776-48db-9ef5-86ab0a0222c7 /boot ext3 defaults 0 0
            # /dev/nvme0n1p4
            UUID=52ad6a6b-7eae-4ebe-ae19-6aab35d7f2fa / ext4 defaults 0 0
            # /dev/nvme1n1
            UUID=6e53e8d0-cbcd-40b0-852a-843c85eb48df /var/storage/devices/disk1 ext4 defaults 0 2
            # /dev/nvme2n1
            UUID=79464f09-9f05-4d05-8bca-77596c398a18 /var/storage/devices/disk2 ext4 defaults 0 2
      FSTAB
    }

    it "configures encrypted swap" do
      expect(File).to receive(:read).with(CryptSwapSetup::FSTAB).and_return(fstab.dup)
      expect(File).to receive(:realpath).with("/dev/disk/by-uuid/4c4fe278-d132-4136-8073-b1242eacf5eb").and_return("/dev/nvme0n1p2")

      expect(Dir).to receive(:[]).with("/dev/disk/by-id/*").and_return(["/dev/disk/by-id/nvme-eui.12345678", "/dev/disk/by-id/wwn-0x87654321"])
      expect(File).to receive(:realpath).with("/dev/disk/by-id/nvme-eui.12345678").and_return("/dev/nvme0n1p2")
      expect(File).to receive(:stat).with("/dev/nvme0n1p2").twice.and_return(instance_double(File::Stat, rdev_major: 259, rdev_minor: 2))

      expect(described_class).to receive(:r).with("swapoff", "/dev/nvme0n1p2")
      expect(File).to receive(:exist?).with(CryptSwapSetup::CRYPTTAB).and_return(false)
      expect(described_class).to receive(:safe_write_to_file).with(CryptSwapSetup::CRYPTTAB, "cryptswap /dev/disk/by-id/nvme-eui.12345678 /dev/urandom cipher=aes-xts-plain64,size=512,swap,discard\n")
      expect(Time).to receive(:now).and_return(Time.at(1_700_000_000))
      expect(FileUtils).to receive(:cp).with(CryptSwapSetup::FSTAB, "#{CryptSwapSetup::FSTAB}.bak.1700000000")
      expect(described_class).to receive(:safe_write_to_file).with(CryptSwapSetup::FSTAB, fstab.sub("UUID=4c4fe278-d132-4136-8073-b1242eacf5eb none swap sw 0 0\n", "/dev/mapper/cryptswap none swap sw 0 0\n"))

      expect(described_class).to receive(:r).with("wipefs", "-a", "/dev/nvme0n1p2")
      expect(described_class).to receive(:r).with("systemctl", "daemon-reload")
      expect(described_class).to receive(:r).with("systemctl", "restart", "systemd-cryptsetup@cryptswap.service")
      expect(described_class).to receive(:r).with("mkswap", "-f", CryptSwapSetup::CRYPTSWAP_DEVICE)
      expect(described_class).to receive(:r).with("swapon", "-a")

      described_class.run
    end
  end
end
