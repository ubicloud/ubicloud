# frozen_string_literal: true

require_relative "../model"

class NicGcpResource < Sequel::Model
  many_to_one :nic, key: :id, read_only: true, is_used: true
  plugin ResourceMethods
end

# Table: nic_gcp_resource
# Columns:
#  id                     | uuid    | PRIMARY KEY
#  address_name           | text    |
#  static_ip              | text    |
#  network_name           | text    |
#  subnet_name            | text    |
#  subnet_tag             | text    |
#  location_id            | uuid    |
#  firewall_base_priority | integer |
# Indexes:
#  nic_gcp_resource_pkey                                | PRIMARY KEY btree (id)
#  nic_gcp_resource_location_firewall_base_priority_idx | UNIQUE btree (location_id, firewall_base_priority) WHERE firewall_base_priority IS NOT NULL
# Check constraints:
#  nic_gcp_resource_firewall_base_priority_check | (firewall_base_priority IS NULL OR firewall_base_priority >= 10000 AND firewall_base_priority <= 59936 AND (firewall_base_priority - 10000) % 64 = 0)
# Foreign key constraints:
#  nic_gcp_resource_id_fkey | (id) REFERENCES nic(id)
