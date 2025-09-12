# frozen_string_literal: true

require_relative "../model"

class DetachableVolume < Sequel::Model
  many_to_one :vm
  many_to_one :source_vhost_block_backend, class: :VhostBlockBackend
  many_to_one :source_key_encryption_key, class: :StorageKeyEncryptionKey
  many_to_one :target_vhost_block_backend, class: :VhostBlockBackend
  many_to_one :target_key_encryption_key, class: :StorageKeyEncryptionKey

  plugin :association_dependencies, source_key_encryption_key: :destroy, target_key_encryption_key: :destroy

  plugin ResourceMethods
  plugin SemaphoreMethods, :destroy
end

# Table: detachable_volume
# Columns:
#  id                            | uuid                     | PRIMARY KEY
#  project_id                    | uuid                     | NOT NULL
#  vm_id                         | uuid                     |
#  source_vhost_block_backend_id | uuid                     |
#  source_key_encryption_key_id  | uuid                     |
#  target_vhost_block_backend_id | uuid                     |
#  target_key_encryption_key_id  | uuid                     |
#  name                          | text                     | NOT NULL
#  size_gib                      | integer                  | NOT NULL
#  max_read_mbytes_per_sec       | integer                  |
#  max_write_mbytes_per_sec      | integer                  |
#  vring_workers                 | integer                  |
#  created_at                    | timestamp with time zone | NOT NULL DEFAULT CURRENT_TIMESTAMP
# Indexes:
#  detachable_volume_pkey                | PRIMARY KEY btree (id)
#  detachable_volume_project_id_name_key | UNIQUE btree (project_id, name)
# Foreign key constraints:
#  detachable_volume_source_key_encryption_key_id_fkey  | (source_key_encryption_key_id) REFERENCES storage_key_encryption_key(id)
#  detachable_volume_source_vhost_block_backend_id_fkey | (source_vhost_block_backend_id) REFERENCES vhost_block_backend(id)
#  detachable_volume_target_key_encryption_key_id_fkey  | (target_key_encryption_key_id) REFERENCES storage_key_encryption_key(id)
#  detachable_volume_target_vhost_block_backend_id_fkey | (target_vhost_block_backend_id) REFERENCES vhost_block_backend(id)
#  detachable_volume_vm_id_fkey                         | (vm_id) REFERENCES vm(id)
