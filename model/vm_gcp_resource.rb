# frozen_string_literal: true

require_relative "../model"

class VmGcpResource < Sequel::Model
  # service_account_email is set once the VM's own service account exists in
  # GCP, and is what the postgres layer checks to decide whether to reach blob
  # storage through the metadata server instead of a per-timeline key.

  many_to_one :vm, key: :id, read_only: true, is_used: true
  many_to_one :location_az, read_only: true
  plugin ResourceMethods, referencing: UBID::TYPE_VM
end

# Table: vm_gcp_resource
# Columns:
#  id                    | uuid                     | PRIMARY KEY
#  location_az_id        | uuid                     | NOT NULL
#  created_at            | timestamp with time zone | NOT NULL DEFAULT CURRENT_TIMESTAMP
#  service_account_email | text                     |
# Indexes:
#  vm_gcp_resource_pkey                 | PRIMARY KEY btree (id)
#  vm_gcp_resource_location_az_id_index | btree (location_az_id)
# Foreign key constraints:
#  vm_gcp_resource_id_fkey             | (id) REFERENCES vm(id) ON DELETE CASCADE
#  vm_gcp_resource_location_az_id_fkey | (location_az_id) REFERENCES location_az(id)
