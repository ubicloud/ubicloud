# frozen_string_literal: true

require_relative "../../model"

class PrivateSubnetAwsResource < Sequel::Model
  include ResourceMethods
  one_to_one :private_subnet, key: :id
  many_to_one :customer_aws_account

  def self.ubid_type
    UBID::TYPE_ETC
  end
end

# Table: private_subnet_aws_resource
# Columns:
#  id                      | uuid | PRIMARY KEY
#  vpc_id                  | text |
#  route_table_id          | text |
#  internet_gateway_id     | text |
#  subnet_id               | text |
#  customer_aws_account_id | uuid |
# Indexes:
#  private_subnet_aws_resource_pkey | PRIMARY KEY btree (id)
# Foreign key constraints:
#  private_subnet_aws_resource_customer_aws_account_id_fkey | (customer_aws_account_id) REFERENCES customer_aws_account(id)
#  private_subnet_aws_resource_id_fkey                      | (id) REFERENCES private_subnet(id)
