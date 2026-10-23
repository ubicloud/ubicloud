# frozen_string_literal: true

require_relative "../model"

class VpcPeeringAwsResource < Sequel::Model
  many_to_one :vpc_peering, key: :id, read_only: true, is_used: true
  plugin ResourceMethods, referencing: UBID::TYPE_VPC_PEERING

  def console_url
    "https://#{peer_region}.console.aws.amazon.com/vpcconsole/home?region=#{peer_region}#PeeringConnectionDetails:VpcPeeringConnectionId=#{peering_connection_id}"
  end
end

# Table: vpc_peering_aws_resource
# Columns:
#  id                    | uuid                     | PRIMARY KEY
#  peer_region           | text                     | NOT NULL
#  peering_connection_id | text                     |
#  requester_account_id  | text                     |
#  expires_at            | timestamp with time zone |
# Indexes:
#  vpc_peering_aws_resource_pkey                      | PRIMARY KEY btree (id)
#  vpc_peering_aws_resource_peering_connection_id_key | UNIQUE btree (peering_connection_id)
# Check constraints:
#  vpc_peering_aws_resource_connection_recorded_check | ((peering_connection_id IS NULL) = (requester_account_id IS NULL))
# Foreign key constraints:
#  vpc_peering_aws_resource_id_fkey | (id) REFERENCES vpc_peering(id) ON DELETE CASCADE
