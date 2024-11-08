# frozen_string_literal: true

require_relative "../model"

class StorageDevice < Sequel::Model
  include ResourceMethods

  many_to_one :vm_host

  def self.ubid_type
    UBID::TYPE_ETC
  end
end

# Table: storage_device
# Columns:
#  id                    | uuid    | PRIMARY KEY
#  name                  | text    | NOT NULL
#  total_storage_gib     | integer | NOT NULL
#  available_storage_gib | integer | NOT NULL
#  enabled               | boolean | NOT NULL DEFAULT true
#  vm_host_id            | uuid    |
# Indexes:
#  storage_device_pkey                | PRIMARY KEY btree (id)
#  storage_device_vm_host_id_name_key | UNIQUE btree (vm_host_id, name)
# Check constraints:
#  available_storage_gib_less_than_or_equal_to_total | (available_storage_gib <= total_storage_gib)
#  available_storage_gib_non_negative                | (available_storage_gib >= 0)
# Foreign key constraints:
#  storage_device_vm_host_id_fkey | (vm_host_id) REFERENCES vm_host(id)
# Referenced By:
#  vm_storage_volume | vm_storage_volume_storage_device_id_fkey | (storage_device_id) REFERENCES storage_device(id)
