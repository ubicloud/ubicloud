# frozen_string_literal: true

require_relative "../model"

class AssignedHostAddress < Sequel::Model
  many_to_one :vm_host, key: :host_id
  many_to_one :address, key: :address_id

  plugin ResourceMethods

  alias_method :admin_label, :ip
end

# Table: assigned_host_address
# Columns:
#  id         | uuid | PRIMARY KEY
#  ip         | cidr | NOT NULL
#  address_id | uuid | NOT NULL
#  host_id    | uuid | NOT NULL
# Indexes:
#  assigned_host_address_pkey   | PRIMARY KEY btree (id)
#  assigned_host_address_ip_key | UNIQUE btree (ip)
# Foreign key constraints:
#  assigned_host_address_address_id_fkey | (address_id) REFERENCES address(id)
#  assigned_host_address_host_id_fkey    | (host_id) REFERENCES vm_host(id)
