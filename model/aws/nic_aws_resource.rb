# frozen_string_literal: true

require_relative "../../model"

class NicAwsResource < Sequel::Model
  include ResourceMethods
  one_to_one :nic, key: :id
  one_to_one :customer_aws_account, key: :customer_aws_account_id

  def self.ubid_type
    UBID::TYPE_ETC
  end
end

# Table: nic_aws_resource
# Columns:
#  id                      | uuid | PRIMARY KEY
#  network_interface_id    | text |
#  elastic_ip_id           | text |
#  key_pair_id             | text |
#  instance_id             | text |
#  customer_aws_account_id | uuid |
# Indexes:
#  nic_aws_resource_pkey | PRIMARY KEY btree (id)
# Foreign key constraints:
#  nic_aws_resource_customer_aws_account_id_fkey | (customer_aws_account_id) REFERENCES customer_aws_account(id)
#  nic_aws_resource_id_fkey                      | (id) REFERENCES nic(id)
