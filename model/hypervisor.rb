# frozen_string_literal: true

require_relative "../model"

class Hypervisor < Sequel::Model
  one_to_many :vms, read_only: true

  plugin ResourceMethods, etc_type: true
end

# Table: hypervisor
# Columns:
#  id      | uuid | PRIMARY KEY
#  name    | text | NOT NULL
#  version | text |
# Indexes:
#  hypervisor_pkey             | PRIMARY KEY btree (id)
#  hypervisor_name_version_key | UNIQUE btree (name, version)
# Check constraints:
#  hypervisor_name_check | (name = ANY (ARRAY['ch'::text, 'qemu'::text]))
# Referenced By:
#  vm | vm_hypervisor_id_fkey | (hypervisor_id) REFERENCES hypervisor(id)
