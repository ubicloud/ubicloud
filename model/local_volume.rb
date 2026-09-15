# frozen_string_literal: true

require_relative "../model"

# Local storage settings for volumes backed by a metal host's own disks.
# Shares its attachment's primary key and is deleted with it.
#
# vm_storage_volume still holds these settings for rows created before this
# table existed. VmStorageVolume#update_local_settings writes both places, and
# .backfill copies the rows that predate it.
class LocalVolume < Sequel::Model
  plugin ResourceMethods, referencing: UBID::TYPE_VM_STORAGE_VOLUME

  SETTINGS = (columns - [:id]).freeze

  # Copies settings from vm_storage_volume in batches, so a large table can be
  # populated without holding one long transaction. Rows already copied are
  # left alone. Returns the number of source rows examined.
  def self.backfill(batch_size: 1000)
    examined = 0
    last_id = nil

    loop do
      source = DB[:vm_storage_volume].order(:id).limit(batch_size).select(:id, *SETTINGS)
      source = source.where { id > last_id } if last_id
      rows = source.all
      break if rows.empty?

      DB[:local_volume].insert_conflict.multi_insert(rows)
      last_id = rows.last[:id]
      examined += rows.length
    end

    examined
  end
end

# Table: local_volume
# Columns:
#  id                       | uuid    | PRIMARY KEY
#  key_encryption_key_1_id  | uuid    |
#  key_encryption_key_2_id  | uuid    |
#  spdk_installation_id     | uuid    |
#  storage_device_id        | uuid    |
#  boot_image_id            | uuid    |
#  machine_image_version_id | uuid    |
#  remote_storage_server_id | uuid    |
#  vhost_block_backend_id   | uuid    |
#  vring_workers            | integer |
#  use_bdev_ubi             | boolean | NOT NULL DEFAULT false
#  track_written            | boolean | NOT NULL DEFAULT false
#  max_read_mbytes_per_sec  | integer |
#  max_write_mbytes_per_sec | integer |
# Indexes:
#  local_volume_pkey | PRIMARY KEY btree (id)
# Check constraints:
#  local_volume_single_source       | (((boot_image_id IS NOT NULL)::integer + (machine_image_version_id IS NOT NULL)::integer + (remote_storage_server_id IS NOT NULL)::integer) <= 1)
#  vring_workers_null_if_not_ubiblk | (vhost_block_backend_id IS NOT NULL OR vring_workers IS NULL)
#  vring_workers_positive_if_ubiblk | (vhost_block_backend_id IS NULL OR vring_workers IS NOT NULL AND vring_workers > 0)
# Foreign key constraints:
#  local_volume_boot_image_id_fkey            | (boot_image_id) REFERENCES boot_image(id)
#  local_volume_id_fkey                       | (id) REFERENCES vm_storage_volume(id) ON DELETE CASCADE
#  local_volume_key_encryption_key_1_id_fkey  | (key_encryption_key_1_id) REFERENCES storage_key_encryption_key(id)
#  local_volume_key_encryption_key_2_id_fkey  | (key_encryption_key_2_id) REFERENCES storage_key_encryption_key(id)
#  local_volume_machine_image_version_id_fkey | (machine_image_version_id) REFERENCES machine_image_version(id)
#  local_volume_remote_storage_server_id_fkey | (remote_storage_server_id) REFERENCES remote_storage_server(id)
#  local_volume_spdk_installation_id_fkey     | (spdk_installation_id) REFERENCES spdk_installation(id)
#  local_volume_storage_device_id_fkey        | (storage_device_id) REFERENCES storage_device(id)
#  local_volume_vhost_block_backend_id_fkey   | (vhost_block_backend_id) REFERENCES vhost_block_backend(id)
