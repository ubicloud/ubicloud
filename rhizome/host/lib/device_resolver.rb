# frozen_string_literal: true

module DeviceResolver
  # When `device_node` is false (default), `path` is expected to be a regular
  # file or directory, and we match by the major/minor of the filesystem it
  # lives on. When true, `path` points to a block-device node itself, so we
  # must match by its rdev major/minor instead — otherwise we'd be comparing
  # to the devtmpfs hosting /dev.
  def persistent_device_id(path, device_node: false)
    path_stat = File.stat(path)
    path_major = device_node ? path_stat.rdev_major : path_stat.dev_major
    path_minor = device_node ? path_stat.rdev_minor : path_stat.dev_minor

    Dir["/dev/disk/by-id/*"].each do |id|
      dev_path = File.realpath(id)
      dev_stat = File.stat(dev_path)
      next unless dev_stat.rdev_major == path_major && dev_stat.rdev_minor == path_minor

      # Choose stable symlink types by subsystem:
      #  - SSDs: Use identifiers starting with 'wwn' (World Wide Name), globally unique.
      #  - NVMe: Use identifiers starting with 'nvme-eui', also globally unique.
      #  - MD devices: Use uuid identifiers.
      #  - LVM/device-mapper: Use LVM uuid identifiers.
      dev = File.basename(dev_path)
      return id if (dev.start_with?("nvme") && id.include?("nvme-eui.")) ||
        (dev.start_with?("sd") && id.include?("wwn-")) ||
        (dev.start_with?("md") && id.include?("md-uuid-")) ||
        (dev.start_with?("dm") && id.include?("dm-uuid-"))
    rescue SystemCallError
      next
    end

    raise "No persistent device ID found for storage path: #{path}"
  end
end
