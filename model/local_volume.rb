# frozen_string_literal: true

require_relative "../model"

# Settings for storage on a metal host's disks. Shares its attachment's
# primary key and is deleted with it. Reads use vm_storage_volume.
class LocalVolume < Sequel::Model
  plugin ResourceMethods, referencing: UBID::TYPE_VM_STORAGE_VOLUME

  SETTINGS = (columns - [:id]).freeze

  # Lower bound for generated UUIDs.
  FIRST_ID = "00000000-0000-0000-0000-000000000000"

  # Scans vm_storage_volume in batches and inserts missing local rows.
  # Existing rows are unchanged. Returns the number of source rows examined and
  # the number copied. Each call scans from the beginning, so examined counts
  # rows already copied. Copying nothing means the scan found no rows missing a
  # local row; it does not check that copies still match their source.
  #
  # New UUIDs can sort behind the cursor. Metal volume creation writes both
  # tables, so those rows do not depend on the scan.
  def self.backfill(batch_size: 1000)
    examined = 0
    copied = 0
    last_id = FIRST_ID

    loop do
      batch_max = nil

      DB.transaction do
        # Lock the source rows for the batch. A concurrent write would
        # otherwise be able to update a source row, see no local row yet, and
        # skip its half of the dual write, leaving this insert to store the
        # older values for good.
        ids = DB[:vm_storage_volume].where { id > last_id }.order(:id).limit(batch_size).for_update.select_map(:id)
        next if ids.empty?

        batch_max = ids.last
        source = DB[:vm_storage_volume].select(:id, *SETTINGS).where { (id > last_id) & (id <= batch_max) }
        copied += DB[:local_volume].insert_conflict.returning(:id).insert([:id, *SETTINGS], source).length
        examined += ids.length
      end

      break unless batch_max
      last_id = batch_max
    end

    {examined:, copied:}
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
