# frozen_string_literal: true

require_relative "../model"

class NicGcpResource < Sequel::Model
  many_to_one :nic, key: :id, read_only: true, is_used: true
  plugin ResourceMethods
end

# Table: nic_gcp_resource
# Columns:
#  id           | uuid | PRIMARY KEY
#  address_name | text |
#  static_ip    | text |
#  network_name | text |
#  subnet_name  | text |
#  subnet_tag   | text |
# Indexes:
#  nic_gcp_resource_pkey | PRIMARY KEY btree (id)
# Foreign key constraints:
#  nic_gcp_resource_id_fkey | (id) REFERENCES nic(id)
