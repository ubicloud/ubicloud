# frozen_string_literal: true

require_relative "../model"
require_relative "../lib/system_parser"

class StorageDevice < Sequel::Model
  many_to_one :vm_host

  plugin ResourceMethods, etc_type: true

  def migrate_device_name_to_device_id
    update(unix_device_list: unix_device_list.map { |device_name| StorageDevice.convert_device_name_to_device_id(vm_host.sshable, device_name) })
  end

  # We have both raided and non-raided servers, in non-raided servers, we can call blkid to get the uuid
  # but in the case of raided servers, all the underlying disk devices will be shown with the same uuid of the raid device
  # (/dev/md) so we end up with duplicate uuids for different ssd or nvme disks. so we won't use /dev/disk/by-uuid
  #
  # to handle this, we would use /dev/disk/by-id instead.
  # For SSD disks, there is a unique identifier which starts with wwn (World Wide Name) which is claimed to be unique across the world
  # For NVMe disks, there is a unique identidier which starts with nvme-eui and it is also claimed to be unique
  #
  # All of our disks are either SSD or NVMe, so the assumptions that we can rely on these two prefixes is reliable
  def self.convert_device_name_to_device_id(sshable, device_name)
    if device_name.start_with?("sd")
      sshable.cmd("ls -l /dev/disk/by-id/ | grep '#{device_name}$' | grep 'wwn-' | sed -E 's/.*(wwn[^ ]*).*/\\1/'").strip
    elsif device_name.start_with?("nvme")
      sshable.cmd("ls -l /dev/disk/by-id/ | grep '#{device_name}$' | grep 'nvme-eui' | sed -E 's/.*(nvme-eui[^ ]*).*/\\1/'").strip
    else
      device_name
    end
  end
end

# Table: storage_device
# Columns:
#  id                    | uuid    | PRIMARY KEY
#  name                  | text    | NOT NULL
#  total_storage_gib     | integer | NOT NULL
#  available_storage_gib | integer | NOT NULL
#  enabled               | boolean | NOT NULL DEFAULT true
#  vm_host_id            | uuid    |
#  unix_device_list      | text[]  |
# Indexes:
#  storage_device_pkey                | PRIMARY KEY btree (id)
#  storage_device_vm_host_id_name_key | UNIQUE btree (vm_host_id, name)
# Check constraints:
#  available_storage_gib_less_than_or_equal_to_total | (available_storage_gib <= total_storage_gib)
#  available_storage_gib_non_negative                | (available_storage_gib >= 0)
# Foreign key constraints:
#  storage_device_vm_host_id_fkey | (vm_host_id) REFERENCES vm_host(id)
# Referenced By:
#  vm_storage_volume | vm_storage_volume_storage_device_id_fkey | (storage_device_id) REFERENCES storage_device(id)
