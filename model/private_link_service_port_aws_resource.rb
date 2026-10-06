# frozen_string_literal: true

require_relative "../model"

# Each port is its own target group and listener on the service's NLB.
class PrivateLinkServicePortAwsResource < Sequel::Model
  many_to_one :private_link_service_port, key: :id, read_only: true
end

# Table: private_link_service_port_aws_resource
# Columns:
#  id               | uuid | PRIMARY KEY
#  target_group_arn | text |
#  listener_arn     | text |
# Indexes:
#  private_link_service_port_aws_resource_pkey | PRIMARY KEY btree (id)
# Foreign key constraints:
#  private_link_service_port_aws_resource_id_fkey | (id) REFERENCES private_link_service_port(id) ON DELETE CASCADE
