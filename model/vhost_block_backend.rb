# frozen_string_literal: true

require_relative "../model"

class VhostBlockBackend < Sequel::Model
  many_to_one :vm_host
  one_to_many :vm_storage_volumes

  def self.generate_uuid
    UBID.generate(UBID::TYPE_ETC).to_uuid
  end
end

# Table: vhost_block_backend
# Columns:
#  id                | uuid                     | PRIMARY KEY
#  created_at        | timestamp with time zone | NOT NULL DEFAULT CURRENT_TIMESTAMP
#  version           | text                     | NOT NULL
#  allocation_weight | integer                  | NOT NULL
#  vm_host_id        | uuid                     | NOT NULL
# Indexes:
#  vhost_block_backend_pkey                   | PRIMARY KEY btree (id)
#  vhost_block_backend_vm_host_id_version_key | UNIQUE btree (vm_host_id, version)
# Foreign key constraints:
#  vhost_block_backend_vm_host_id_fkey | (vm_host_id) REFERENCES vm_host(id)
# Referenced By:
#  vm_storage_volume | vm_storage_volume_vhost_block_backend_id_fkey | (vhost_block_backend_id) REFERENCES vhost_block_backend(id)
