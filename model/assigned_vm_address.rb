# frozen_string_literal: true

require_relative "../model"

class AssignedVmAddress < Sequel::Model
  many_to_one :vm, key: :dst_vm_id
  many_to_one :address
  one_to_one :active_billing_record, class: :BillingRecord, key: :resource_id, &:active

  plugin ResourceMethods

  alias_method :admin_label, :ip
end

# Table: assigned_vm_address
# Columns:
#  id         | uuid | PRIMARY KEY
#  ip         | cidr | NOT NULL
#  address_id | uuid |
#  dst_vm_id  | uuid | NOT NULL
# Indexes:
#  assigned_vm_address_pkey   | PRIMARY KEY btree (id)
#  assigned_vm_address_ip_key | UNIQUE btree (ip)
# Foreign key constraints:
#  assigned_vm_address_address_id_fkey | (address_id) REFERENCES address(id)
#  assigned_vm_address_dst_vm_id_fkey  | (dst_vm_id) REFERENCES vm(id)
