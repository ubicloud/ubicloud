# frozen_string_literal: true

require_relative "../model"

class VpcPeeringGcpResource < Sequel::Model
  many_to_one :vpc_peering, key: :id, read_only: true, is_used: true
  plugin ResourceMethods, referencing: UBID::TYPE_VPC_PEERING
end

# Table: vpc_peering_gcp_resource
# Columns:
#  id           | uuid | PRIMARY KEY
#  peering_name | text | NOT NULL
# Indexes:
#  vpc_peering_gcp_resource_pkey | PRIMARY KEY btree (id)
# Foreign key constraints:
#  vpc_peering_gcp_resource_id_fkey | (id) REFERENCES vpc_peering(id)
