# frozen_string_literal: true

require_relative "../model"

class VpcPeering < Sequel::Model
  many_to_one :private_subnet, read_only: true
  one_to_one :vpc_peering_aws_resource, key: :id, read_only: true

  plugin :association_dependencies, vpc_peering_aws_resource: :destroy
  plugin ResourceMethods
  plugin SemaphoreMethods, :destroy
end

# Table: vpc_peering
# Columns:
#  id                | uuid                     | PRIMARY KEY DEFAULT gen_random_ubid_uuid(733)
#  private_subnet_id | uuid                     | NOT NULL
#  peer_account_id   | text                     | NOT NULL
#  peer_vpc_id       | text                     | NOT NULL
#  state             | text                     | NOT NULL DEFAULT 'creating'::text
#  state_message     | text                     |
#  peer_cidrs        | cidr[]                   | NOT NULL DEFAULT '{}'::cidr[]
#  created_at        | timestamp with time zone | NOT NULL DEFAULT CURRENT_TIMESTAMP
# Indexes:
#  vpc_peering_pkey                              | PRIMARY KEY btree (id)
#  vpc_peering_private_subnet_id_peer_vpc_id_key | UNIQUE btree (private_subnet_id, peer_vpc_id)
# Check constraints:
#  vpc_peering_failed_message_check | (state <> 'failed'::text OR state_message IS NOT NULL)
#  vpc_peering_state_check          | (state = ANY (ARRAY['creating'::text, 'waiting_for_peer'::text, 'configuring'::text, 'active'::text, 'failed'::text]))
# Foreign key constraints:
#  vpc_peering_private_subnet_id_fkey | (private_subnet_id) REFERENCES private_subnet(id)
# Referenced By:
#  vpc_peering_aws_resource | vpc_peering_aws_resource_id_fkey | (id) REFERENCES vpc_peering(id) ON DELETE CASCADE
