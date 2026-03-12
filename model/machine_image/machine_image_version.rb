# frozen_string_literal: true

require_relative "../../model"

class MachineImageVersion < Sequel::Model
  one_to_one :strand, key: :id
  one_to_one :metal, class: :MachineImageVersionMetal, key: :id, read_only: true

  many_to_one :machine_image
  one_to_many :vm_storage_volumes, read_only: true
  one_to_many :active_billing_records, class: :BillingRecord, key: :resource_id, read_only: true, &:active

  plugin ResourceMethods
end

# Table: machine_image_version
# Columns:
#  id               | uuid                     | PRIMARY KEY DEFAULT gen_random_ubid_uuid(667)
#  machine_image_id | uuid                     | NOT NULL
#  version          | text                     | NOT NULL
#  created_at       | timestamp with time zone | NOT NULL DEFAULT CURRENT_TIMESTAMP
#  actual_size_mib  | integer                  |
# Indexes:
#  machine_image_version_pkey                         | PRIMARY KEY btree (id)
#  machine_image_version_machine_image_id_version_key | UNIQUE btree (machine_image_id, version)
# Foreign key constraints:
#  machine_image_version_machine_image_id_fkey | (machine_image_id) REFERENCES machine_image(id)
# Referenced By:
#  machine_image               | machine_image_latest_version_id_fkey            | (latest_version_id) REFERENCES machine_image_version(id)
#  machine_image_version_metal | machine_image_version_metal_id_fkey             | (id) REFERENCES machine_image_version(id)
#  vm_storage_volume           | vm_storage_volume_machine_image_version_id_fkey | (machine_image_version_id) REFERENCES machine_image_version(id)
