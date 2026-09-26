# frozen_string_literal: true

require_relative "../model"

class DetachableVolume < Sequel::Model
  one_to_one :strand, key: :id
  many_to_one :project
  many_to_one :location
  many_to_one :vm_host
  many_to_one :key_encryption_key_1, class: :StorageKeyEncryptionKey
  many_to_one :key_encryption_key_2, class: :StorageKeyEncryptionKey, read_only: true
  plugin :association_dependencies, key_encryption_key_1: :destroy, key_encryption_key_2: :destroy

  plugin ResourceMethods
  plugin SemaphoreMethods, :destroy

  def record_host(host:)
    update(vm_host_id: host.id)
  end

  def self.wrap_xts(kek)
    kek.encrypt(SecureRandom.bytes(64), "xts-key")
  end

  def key_material
    {"kek" => key_encryption_key_1.key, "wrapped_xts" => wrapped_xts}
  end

  def stripe_source_for(target_host)
    return {"type" => "new", "image" => source_image} unless vm_host_id
    {"type" => "local"} if vm_host_id == target_host.id
  end
end

# Table: detachable_volume
# Columns:
#  id                      | uuid                     | PRIMARY KEY DEFAULT gen_random_ubid_uuid(443)
#  created_at              | timestamp with time zone | NOT NULL DEFAULT CURRENT_TIMESTAMP
#  project_id              | uuid                     | NOT NULL
#  location_id             | uuid                     | NOT NULL
#  size_gib                | integer                  | NOT NULL
#  vm_host_id              | uuid                     |
#  key_encryption_key_1_id | uuid                     | NOT NULL
#  key_encryption_key_2_id | uuid                     |
#  wrapped_xts             | text                     | NOT NULL
#  source_image            | text                     | NOT NULL
# Indexes:
#  detachable_volume_pkey           | PRIMARY KEY btree (id)
#  detachable_volume_vm_host_id_idx | btree (vm_host_id)
# Foreign key constraints:
#  detachable_volume_key_encryption_key_1_id_fkey | (key_encryption_key_1_id) REFERENCES storage_key_encryption_key(id)
#  detachable_volume_key_encryption_key_2_id_fkey | (key_encryption_key_2_id) REFERENCES storage_key_encryption_key(id)
#  detachable_volume_location_id_fkey             | (location_id) REFERENCES location(id)
#  detachable_volume_project_id_fkey              | (project_id) REFERENCES project(id)
#  detachable_volume_vm_host_id_fkey              | (vm_host_id) REFERENCES vm_host(id)
# Referenced By:
#  remote_storage_server | remote_storage_server_source_detachable_volume_id_fkey | (source_detachable_volume_id) REFERENCES detachable_volume(id)
