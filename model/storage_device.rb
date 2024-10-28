# frozen_string_literal: true

require_relative "../model"

class StorageDevice < Sequel::Model
  many_to_one :vm_host
  one_to_many :vm_storage_volumes

  include ResourceMethods

  DEFAULT_NAME = "DEFAULT"

  def self.ubid_type
    UBID::TYPE_ETC
  end

  def blk_dev_serial_number
    super || populate_blk_dev_serial_number
  end

  def populate_blk_dev_serial_number
    lsblk_output = JSON.parse(vm_host.sshable.cmd("lsblk -Jno NAME,MOUNTPOINTS,SERIAL"))
    fail "Expected blockdevices in lsblk output" unless lsblk_output.key?("blockdevices")
    devices = []

    lsblk_output["blockdevices"].each do |bdev|
      raise "Expected non-empty serial number in lsblk command while fetching data for vm_host #{vm_host.id}" unless bdev.key?("serial") && !bdev["serial"].to_s.strip.empty?
      devices << bdev["serial"] if has_mount_point?(bdev)
    end
    devices.uniq!
    update(blk_dev_serial_number: devices)
    devices
  end

  private

  def mount_point = (name == DEFAULT_NAME) ? "/" : "/var/storage/devices/#{name}"

  # Recursively checks if the json object has mount_point in the mountpoints list.
  # Expected structure: type x = {"mountpoints": []string, "children": []x}
  def has_mount_point?(jobj)
    jobj.fetch("mountpoints", []).any?(mount_point) || jobj.fetch("children", []).any? { |child| has_mount_point?(child) }
  end
end
