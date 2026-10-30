# frozen_string_literal: true

require_relative "../model"

class GcpVpc < Sequel::Model
  one_to_one :strand, key: :id
  many_to_one :project
  many_to_one :location, read_only: true
  many_to_one :dedicated_for_private_subnet, class: :PrivateSubnet, key: :dedicated_for_subnet_id, read_only: true
  many_to_many :private_subnets, join_table: :private_subnet_gcp_vpc, remover: nil, clearer: nil

  plugin ResourceMethods
  plugin SemaphoreMethods, :destroy, :update_firewall_rules
end

# Table: gcp_vpc
# Columns:
#  id                      | uuid    | PRIMARY KEY DEFAULT gen_random_ubid_uuid(539)
#  project_id              | uuid    | NOT NULL
#  location_id             | uuid    | NOT NULL
#  name                    | text    | NOT NULL
#  network_self_link       | text    |
#  dedicated_for_subnet_id | uuid    |
#  is_management           | boolean | NOT NULL DEFAULT false
#  peer_network            | text    |
#  peering_state           | text    |
#  peering_state_message   | text    |
# Indexes:
#  gcp_vpc_pkey                               | PRIMARY KEY btree (id)
#  gcp_vpc_dedicated_for_subnet_id_uidx       | UNIQUE btree (dedicated_for_subnet_id) WHERE dedicated_for_subnet_id IS NOT NULL
#  gcp_vpc_project_id_location_id_shared_uidx | UNIQUE btree (project_id, location_id) WHERE dedicated_for_subnet_id IS NULL
# Check constraints:
#  gcp_vpc_peering_config_check    | ((peer_network IS NULL) = (peering_state IS NULL))
#  gcp_vpc_peering_dedicated_check | (peer_network IS NULL OR dedicated_for_subnet_id IS NOT NULL AND NOT is_management)
#  gcp_vpc_peering_state_check     | (peering_state = ANY (ARRAY['creating'::text, 'waiting_for_peer'::text, 'active'::text, 'failed'::text, 'deleting'::text]))
# Foreign key constraints:
#  gcp_vpc_dedicated_for_subnet_id_fkey | (dedicated_for_subnet_id) REFERENCES private_subnet(id)
#  gcp_vpc_location_id_fkey             | (location_id) REFERENCES location(id)
#  gcp_vpc_project_id_fkey              | (project_id) REFERENCES project(id)
# Referenced By:
#  private_subnet_gcp_vpc | private_subnet_gcp_vpc_gcp_vpc_id_fkey | (gcp_vpc_id) REFERENCES gcp_vpc(id) ON DELETE CASCADE
