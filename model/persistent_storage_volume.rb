# frozen_string_literal: true

require_relative "../model"

class PersistentStorageVolume < Sequel::Model
  many_to_one :project
  many_to_one :vm_host
  many_to_one :key_encryption_key, class: :StorageKeyEncryptionKey
  one_to_one :vm_storage_volume

  plugin :association_dependencies, key_encryption_key: :destroy

  plugin ResourceMethods
end

# Table: persistent_storage_volume
# Columns:
#  id                     | uuid                     | PRIMARY KEY
#  project_id             | uuid                     | NOT NULL
#  vm_host_id             | uuid                     |
#  vhost_block_backend_id | uuid                     |
#  vm_storage_volume_id   | uuid                     |
#  migration_port         | integer                  |
#  key_encryption_key_id  | uuid                     |
#  name                   | text                     | NOT NULL
#  size_gib               | integer                  | NOT NULL
#  created_at             | timestamp with time zone | NOT NULL DEFAULT CURRENT_TIMESTAMP
# Indexes:
#  persistent_storage_volume_pkey                          | PRIMARY KEY btree (id)
#  persistent_storage_volume_project_id_name_key           | UNIQUE btree (project_id, name)
#  persistent_storage_volume_vm_host_id_migration_port_key | UNIQUE btree (vm_host_id, migration_port)
# Check constraints:
#  persistent_storage_volume_check | ((vm_host_id IS NULL) = (vhost_block_backend_id IS NULL) AND (vm_host_id IS NULL) = (key_encryption_key_id IS NULL))
# Foreign key constraints:
#  persistent_storage_volume_key_encryption_key_id_fkey  | (key_encryption_key_id) REFERENCES storage_key_encryption_key(id)
#  persistent_storage_volume_vhost_block_backend_id_fkey | (vhost_block_backend_id) REFERENCES vhost_block_backend(id)
#  persistent_storage_volume_vm_host_id_fkey             | (vm_host_id) REFERENCES vm_host(id)
#  persistent_storage_volume_vm_storage_volume_id_fkey   | (vm_storage_volume_id) REFERENCES vm_storage_volume(id)
# Referenced By:
#  vm_storage_volume | vm_storage_volume_persistent_storage_volume_id_fkey | (persistent_storage_volume_id) REFERENCES persistent_storage_volume(id)
