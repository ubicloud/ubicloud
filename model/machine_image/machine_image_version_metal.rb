# frozen_string_literal: true

require_relative "../../model"

class MachineImageVersionMetal < Sequel::Model
  many_to_one :machine_image_version, key: :id, read_only: true, is_used: true
  many_to_one :store, class: :MachineImageStore
  many_to_one :archive_kek, class: :StorageKeyEncryptionKey

  plugin ResourceMethods, etc_type: true
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
