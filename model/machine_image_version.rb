# frozen_string_literal: true

require_relative "../model"

class MachineImageVersion < Sequel::Model
  one_to_one :strand, key: :id

  many_to_one :machine_image
  many_to_one :key_encryption_key, class: :StorageKeyEncryptionKey
  one_to_many :vm_storage_volumes, read_only: true
  one_to_many :active_billing_records, class: :BillingRecord, key: :resource_id, read_only: true, &:active

  plugin ResourceMethods
end

# Table: machine_image_version
# Columns:
#  id                    | uuid                     | PRIMARY KEY
#  machine_image_id      | uuid                     | NOT NULL
#  version               | text                     | NOT NULL
#  created_at            | timestamp with time zone | NOT NULL DEFAULT CURRENT_TIMESTAMP
#  enabled               | boolean                  | NOT NULL DEFAULT false
#  actual_size_mib       | integer                  | NOT NULL
#  archive_size_mib      | integer                  |
#  key_encryption_key_id | uuid                     | NOT NULL
#  s3_endpoint           | text                     | NOT NULL
#  s3_bucket             | text                     | NOT NULL
#  s3_prefix             | text                     | NOT NULL
# Indexes:
#  machine_image_version_pkey                         | PRIMARY KEY btree (id)
#  machine_image_version_machine_image_id_version_key | UNIQUE btree (machine_image_id, version)
# Foreign key constraints:
#  machine_image_version_key_encryption_key_id_fkey | (key_encryption_key_id) REFERENCES storage_key_encryption_key(id)
#  machine_image_version_machine_image_id_fkey      | (machine_image_id) REFERENCES machine_image(id)
# Referenced By:
#  machine_image     | machine_image_latest_version_id_fkey            | (latest_version_id) REFERENCES machine_image_version(id)
#  vm_storage_volume | vm_storage_volume_machine_image_version_id_fkey | (machine_image_version_id) REFERENCES machine_image_version(id)
