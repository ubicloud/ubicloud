# frozen_string_literal: true

require_relative "../model"

class Address < Sequel::Model
  one_to_many :assigned_vm_addresses, key: :address_id, class: :AssignedVmAddress
  one_to_many :assigned_host_addresses, key: :address_id, class: :AssignedHostAddress

  plugin ResourceMethods
end

# Table: address
# Columns:
#  id                | uuid    | PRIMARY KEY
#  cidr              | cidr    | NOT NULL
#  is_failover_ip    | boolean | NOT NULL DEFAULT false
#  routed_to_host_id | uuid    | NOT NULL
# Indexes:
#  address_pkey     | PRIMARY KEY btree (id)
#  address_cidr_key | UNIQUE btree (cidr)
# Foreign key constraints:
#  address_routed_to_host_id_fkey | (routed_to_host_id) REFERENCES vm_host(id)
# Referenced By:
#  assigned_host_address | assigned_host_address_address_id_fkey | (address_id) REFERENCES address(id)
#  assigned_vm_address   | assigned_vm_address_address_id_fkey   | (address_id) REFERENCES address(id)
#  ipv4_address          | ipv4_address_cidr_fkey                | (cidr) REFERENCES address(cidr)
