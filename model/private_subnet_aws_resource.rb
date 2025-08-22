# frozen_string_literal: true

require_relative "../model"

class PrivateSubnetAwsResource < Sequel::Model
  many_to_one :private_subnet, key: :id

  plugin ResourceMethods
end

# Table: private_subnet_aws_resource
# Columns:
#  id                  | uuid | PRIMARY KEY
#  vpc_id              | text |
#  internet_gateway_id | text |
#  route_table_id      | text |
#  security_group_id   | text |
# Indexes:
#  private_subnet_aws_resource_pkey | PRIMARY KEY btree (id)
# Foreign key constraints:
#  private_subnet_aws_resource_id_fkey | (id) REFERENCES private_subnet(id)
