#!/usr/bin/env ruby
# frozen_string_literal: true

require "fileutils"

N = 3 # Number of loopback devices to create

FileUtils.mkdir_p("/var/storage/devices")

# Get free space in bytes
free_space_bytes = Integer(`df -B 1 --output=avail /var/storage | tail -n 1`)

# Of the free space, use half of it for multi-device modeling,
# rounding to the nearest 4K page for device size to suppress annoying
# warning messages.
device_size_bytes = (free_space_bytes / (N * 2 * 4096)) * 4096

(1..N).each do |i|
  # Create loopback file
  FileUtils.touch("/var/storage/loopback#{i}")
  `sudo fallocate -l #{device_size_bytes} /var/storage/loopback#{i}`

  losetup_unit_name = "loopback#{i}.service"
  # Set up loopback devices now and on boot.
  #
  # https://askubuntu.com/questions/1142417/how-do-i-set-up-a-loop-device-at-startup-with-service
  losetup_unit = <<LOSETUP
[Unit]
Description=Mount Loopback Device #{i}
DefaultDependencies=no
Conflicts=umount.target
Before=local-fs.target
After=systemd-udevd.service home.mount
Require=systemd-udevd.service

[Service]
Type=oneshot
ExecStart=/sbin/losetup /dev/loop#{i} /var/storage/loopback#{i}
ExecStop=/sbin/losetup -d /dev/loop#{i}
TimeoutSec=60
RemainAfterExit=yes

[Install]
WantedBy=local-fs.target
Also=systemd-udevd.service
LOSETUP

  File.write("/etc/systemd/system/#{losetup_unit_name}", losetup_unit)
  `sudo systemctl daemon-reload`
  `sudo systemctl enable --now -- #{losetup_unit_name}`

  # Format file system
  `sudo mkfs.ext4 /dev/loop#{i}`

  where = "/var/storage/devices/stor#{i}"
  mount_unit = <<MOUNT
[Unit]
Description=Mount device#{i} on #{where}

[Mount]
What=/dev/loop#{i}
Where=#{where}

[Install]
WantedBy=multi-user.target
MOUNT

  mount_unit_name = where[1..].tr("/", "-") + ".mount"
  File.write("/etc/systemd/system/#{mount_unit_name}", mount_unit)
  `sudo systemctl daemon-reload`
  `sudo systemctl enable --now -- #{mount_unit_name}`
end

puts "Loopback devices created and mounted!"
