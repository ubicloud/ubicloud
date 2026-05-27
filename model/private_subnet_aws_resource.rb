# frozen_string_literal: true

require_relative "../model"

class PrivateSubnetAwsResource < Sequel::Model
  many_to_one :private_subnet, key: :id, read_only: true, is_used: true
  one_to_many :aws_subnets, read_only: true, order: :location_aws_az_id
  plugin ResourceMethods, referencing: UBID::TYPE_PRIVATE_SUBNET

  # Fallback while renaming security_group_id → user_security_group_id.
  # :nocov:
  def user_security_group_id
    self[:user_security_group_id] || self[:security_group_id]
  end
  # :nocov:
end

# Table: private_subnet_aws_resource
# Columns:
#  id                     | uuid | PRIMARY KEY
#  vpc_id                 | text |
#  internet_gateway_id    | text |
#  route_table_id         | text |
#  mgmt_security_group_id | text |
#  user_security_group_id | text |
# Indexes:
#  private_subnet_aws_resource_pkey | PRIMARY KEY btree (id)
# Foreign key constraints:
#  private_subnet_aws_resource_id_fkey | (id) REFERENCES private_subnet(id)
# Referenced By:
#  aws_subnet | aws_subnet_private_subnet_aws_resource_id_fkey | (private_subnet_aws_resource_id) REFERENCES private_subnet_aws_resource(id) ON DELETE CASCADE
