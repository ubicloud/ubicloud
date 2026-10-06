# frozen_string_literal: true

require_relative "../model"

# A consumer VPC endpoint the owner approved, with the owner's note on it.
class PrivateLinkServiceAwsAllowedEndpoint < Sequel::Model
  many_to_one :private_link_service_aws_resource, read_only: true
end

# Table: private_link_service_aws_allowed_endpoint
# Columns:
#  id                                   | uuid | PRIMARY KEY DEFAULT gen_random_ubid_uuid(474)
#  private_link_service_aws_resource_id | uuid | NOT NULL
#  vpc_endpoint_id                      | text | NOT NULL
#  description                          | text | NOT NULL DEFAULT ''::text
# Indexes:
#  private_link_service_aws_allowed_endpoint_pkey                  | PRIMARY KEY btree (id)
#  private_link_service_aws_allo_private_link_service_aws_reso_key | UNIQUE btree (private_link_service_aws_resource_id, vpc_endpoint_id)
# Foreign key constraints:
#  private_link_service_aws_allo_private_link_service_aws_res_fkey | (private_link_service_aws_resource_id) REFERENCES private_link_service_aws_resource(id) ON DELETE CASCADE
