# frozen_string_literal: true

require_relative "../../model"

class CustomerAwsAccount < Sequel::Model
  include ResourceMethods
  one_to_one :private_subnet_aws_resource, key: :customer_aws_account_id
  one_to_one :nic_aws_resource, key: :customer_aws_account_id
  many_to_one :provider_location
  def self.ubid_type
    UBID::TYPE_ETC
  end

  def path
    "/region/#{ubid}"
  end
end

# Table: customer_aws_account
# Columns:
#  id                            | uuid | PRIMARY KEY
#  aws_account_access_key        | text |
#  aws_account_secret_access_key | text |
#  location                      | text |
# Indexes:
#  customer_aws_account_pkey | PRIMARY KEY btree (id)
# Referenced By:
#  nic_aws_resource            | nic_aws_resource_customer_aws_account_id_fkey            | (customer_aws_account_id) REFERENCES customer_aws_account(id)
#  private_subnet_aws_resource | private_subnet_aws_resource_customer_aws_account_id_fkey | (customer_aws_account_id) REFERENCES customer_aws_account(id)
