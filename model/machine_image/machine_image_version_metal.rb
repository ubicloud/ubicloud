# frozen_string_literal: true

require_relative "../../model"

class MachineImageVersionMetal < Sequel::Model
  many_to_one :machine_image_version, key: :id, read_only: true, is_used: true
  many_to_one :store, class: :MachineImageStore, read_only: true
  many_to_one :archive_kek, class: :StorageKeyEncryptionKey, read_only: true
  one_to_many :vm_storage_volumes, key: :machine_image_version_id, read_only: true

  plugin ResourceMethods, referencing: UBID::TYPE_MACHINE_IMAGE_VERSION
  plugin SemaphoreMethods, :destroy

  # Convenience entry point for interactive (pry) destruction. Holds a row lock
  # on the metal row, refuses if it's the latest version or if any VMs still
  # reference it, then schedules destruction via the destroy semaphore.
  def request_destroy
    DB.transaction do
      # Explicit lock to serialize with finish_create's FOR SHARE; don't rely
      # on update(enabled: false) below to acquire it.
      this.for_update.first
      update(enabled: false)
      miv = machine_image_version
      if miv.machine_image.this.get(:latest_version_id) == miv.id
        fail "Cannot destroy the latest version of a machine image"
      end
      unless vm_storage_volumes_dataset.empty?
        fail "VMs are still using this machine image version"
      end
      incr_destroy
    end
  end
end

# Table: machine_image_version_metal
# Columns:
#  id               | uuid    | PRIMARY KEY
#  enabled          | boolean | NOT NULL DEFAULT false
#  archive_size_mib | integer |
#  archive_kek_id   | uuid    | NOT NULL
#  store_id         | uuid    | NOT NULL
#  store_prefix     | text    | NOT NULL
# Indexes:
#  machine_image_version_metal_pkey | PRIMARY KEY btree (id)
# Check constraints:
#  size_set_if_enabled | (NOT enabled OR archive_size_mib IS NOT NULL)
# Foreign key constraints:
#  machine_image_version_metal_archive_kek_id_fkey | (archive_kek_id) REFERENCES storage_key_encryption_key(id)
#  machine_image_version_metal_id_fkey             | (id) REFERENCES machine_image_version(id)
#  machine_image_version_metal_store_id_fkey       | (store_id) REFERENCES machine_image_store(id)
