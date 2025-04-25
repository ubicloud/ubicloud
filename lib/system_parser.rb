# frozen_string_literal: true

class SystemParser
  DfRecord = Struct.new(:unix_device, :optional_name, :size_gib, :avail_gib)

  def self.get_device_mount_points_from_lsblk_json(json_input, device_name)
    data = JSON.parse(json_input)
    excluded_mounts = ["[SWAP]", "/boot", "/boot/efi", nil]

    mount_points = {}

    data["blockdevices"].each do |device|
      next unless device_name == device["name"]

      get_mounts = lambda do |dev|
        dev["mountpoints"]&.each do |mount|
          (mount_points[device["name"]] ||= []) << mount unless excluded_mounts.include?(mount)
        end
        dev["children"]&.each(&get_mounts)
      end

      get_mounts.call(device)
    end

    mount_points
  end

  # By providing /proc/mdstat content file and device name to this method,
  # ["nvme0n1", "nvme1n1"] will be outputted
  #
  # Sample /proc/mdstat file:
  #
  # Personalities : [raid1] [linear] [multipath] [raid0] [raid6] [raid5] [raid4] [raid10]
  # md2 : active raid1 nvme1n1p3[1] nvme0n1p3[0]
  #       465370432 blocks super 1.2 [2/2] [UU]
  #       bitmap: 3/4 pages [12KB], 65536KB chunk
  #
  # md0 : active raid1 nvme1n1p1[1] nvme0n1p1[0]
  #       33520640 blocks super 1.2 [2/2] [UU]
  #
  # md1 : active raid1 nvme1n1p2[1] nvme0n1p2[0]
  #       1046528 blocks super 1.2 [2/2] [UU]
  #
  # unused devices: <none>
  #
  def self.extract_underlying_raid_devices_from_mdstat(mdstat_file_content, raid_device_name)
    section_match = mdstat_file_content.match(/^#{raid_device_name.delete_prefix("/dev/")}\s*:\s*active\s+\w+\s*(.+?)\n/m)

    return [] unless section_match

    section_match[1].scan(/(\w+?)(?:p\d+)?\[\d+\]/).flatten.uniq
  end

  def self.df_command(path = "") = "df -B1 --output=source,target,size,avail #{path}"

  # By providing the output of df, you will get an array containing filename, mountpoint and size and available space
  #
  # Sample output of df command
  #
  # Filesystem     Mounted on    1B-blocks        Avail
  # /dev/md2       /          467909804032 433234698240
  def self.extract_disk_info_from_df(df_output)
    s = StringScanner.new(df_output)
    fail "BUG: df header parse failed" unless s.scan(/\AFilesystem\s+Mounted on\s+1B-blocks\s+Avail\n/)
    out = []

    until s.eos?
      fail "BUG: df data parse failed" unless s.scan(/(.*?)\s(.*?)\s+(\d+)\s+(\d+)\s*\n/)
      optional_name = if s.captures[1] =~ %r{/var/storage/devices/(.*)?}
        $1
      end
      unix_device = s.captures.first
      size_gib, avail_gib = s.captures[2..].map { Integer(it) / 1073741824 }
      out << DfRecord.new(unix_device, optional_name, size_gib, avail_gib)
    end

    out.freeze
  end
end
