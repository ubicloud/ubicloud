# frozen_string_literal: true

require_relative "../../common/lib/util"
require "fileutils"

# Formats every disk except the boot disk and mounts it persistently
# under /var/storage/devices, to be used for VM storage. It is idempotent:
# disks already recorded in /etc/fstab or already mounted are left untouched,
# so it is safe to re-run on a live host.
class StorageDiskFormatter
  FSTAB = "/etc/fstab"

  def format
    data_disks.each_with_index do |disk, index|
      format_disk(disk, mount_dir(index))
    end
    r "mount -a"
  end

  def mount_dir(index)
    "/var/storage/devices/disk#{index + 1}"
  end

  def boot_disk
    @boot_disk ||= begin
      boot_partition = r("findmnt -n -o SOURCE /boot").strip
      boot_disk = r("lsblk -no PKNAME #{boot_partition.shellescape}").strip
      fail "could not determine the boot disk" if boot_disk.empty?
      boot_disk
    end
  end

  def data_disks
    disk_names = r("lsblk -ndo NAME,TYPE").lines.filter_map { |line|
      name, type = line.split
      name if type == "disk"
    }.sort
    (disk_names - [boot_disk]).map { "/dev/#{_1}" }
  end

  def format_disk(disk, mount_dir)
    return if File.read(FSTAB).lines.any? { _1.split[1] == mount_dir }
    return unless r("lsblk -no MOUNTPOINTS #{disk.shellescape}").strip.empty?

    r "wipefs -fa #{disk.shellescape}"
    r "mkfs.ext4 #{disk.shellescape}"
    FileUtils.mkdir_p(mount_dir)
    r "mount #{disk.shellescape} #{mount_dir.shellescape}"

    uuid = r("blkid -s UUID -o value #{disk.shellescape}").strip
    File.open(FSTAB, File::RDONLY) do |f|
      f.flock(File::LOCK_EX)
      safe_write_to_file(FSTAB, f.read + "# #{disk}\nUUID=#{uuid} #{mount_dir} ext4 defaults 0 2\n")
    end
  end
end
