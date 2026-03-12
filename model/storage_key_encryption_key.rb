# frozen_string_literal: true

require_relative "../model"

class StorageKeyEncryptionKey < Sequel::Model
  plugin ResourceMethods, encrypted_columns: [:key, :init_vector]

  def self.create_random(auth_data:, algorithm: "aes-256-gcm")
    key = SecureRandom.random_bytes(32)
    init_vector = SecureRandom.random_bytes(12)
    create(
      algorithm:,
      key: Base64.strict_encode64(key),
      init_vector: Base64.strict_encode64(init_vector),
      auth_data:
    )
  end

  def secret_key_material_hash
    # default to_hash doesn't decrypt encrypted columns, so implement
    # this to decrypt keys when they need to be sent to a running copy
    # of spdk.
    {
      "key" => key,
      "init_vector" => init_vector,
      "algorithm" => algorithm,
      "auth_data" => auth_data
    }
  end
end

# Table: storage_key_encryption_key
# Columns:
#  id          | uuid                     | PRIMARY KEY
#  algorithm   | text                     | NOT NULL
#  key         | text                     | NOT NULL
#  init_vector | text                     | NOT NULL
#  auth_data   | text                     | NOT NULL
#  created_at  | timestamp with time zone | NOT NULL DEFAULT now()
# Indexes:
#  storage_key_encryption_key_pkey | PRIMARY KEY btree (id)
# Referenced By:
#  machine_image_version | machine_image_version_key_encryption_key_id_fkey | (key_encryption_key_id) REFERENCES storage_key_encryption_key(id)
#  vm_storage_volume     | vm_storage_volume_key_encryption_key_1_id_fkey   | (key_encryption_key_1_id) REFERENCES storage_key_encryption_key(id)
#  vm_storage_volume     | vm_storage_volume_key_encryption_key_2_id_fkey   | (key_encryption_key_2_id) REFERENCES storage_key_encryption_key(id)
