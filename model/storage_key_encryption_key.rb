# frozen_string_literal: true

require_relative "../model"

class StorageKeyEncryptionKey < Sequel::Model
  plugin :column_encryption do |enc|
    enc.column :key
    enc.column :init_vector
  end

  plugin ResourceMethods

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
#  vm_storage_volume | vm_storage_volume_key_encryption_key_1_id_fkey | (key_encryption_key_1_id) REFERENCES storage_key_encryption_key(id)
#  vm_storage_volume | vm_storage_volume_key_encryption_key_2_id_fkey | (key_encryption_key_2_id) REFERENCES storage_key_encryption_key(id)
