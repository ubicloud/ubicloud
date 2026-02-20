# frozen_string_literal: true

require_relative "../model"

class AwsSubnet < Sequel::Model
  many_to_one :location_aws_az, read_only: true
  plugin ResourceMethods

  def az_suffix
    location_aws_az.az
  end
end

# Table: aws_subnet
# Columns:
#  id                             | uuid | PRIMARY KEY DEFAULT gen_random_ubid_uuid(345)
#  subnet_id                      | text |
#  ipv4_cidr                      | cidr | NOT NULL
#  ipv6_cidr                      | cidr |
#  private_subnet_aws_resource_id | uuid | NOT NULL
#  location_aws_az_id             | uuid | NOT NULL
# Indexes:
#  aws_subnet_pkey                                                 | PRIMARY KEY btree (id)
#  aws_subnet_private_subnet_aws_resource_id_location_aws_az_i_key | UNIQUE btree (private_subnet_aws_resource_id, location_aws_az_id)
#  aws_subnet_private_subnet_aws_resource_id_index                 | btree (private_subnet_aws_resource_id)
# Foreign key constraints:
#  aws_subnet_location_aws_az_id_fkey             | (location_aws_az_id) REFERENCES location_aws_az(id)
#  aws_subnet_private_subnet_aws_resource_id_fkey | (private_subnet_aws_resource_id) REFERENCES private_subnet_aws_resource(id) ON DELETE CASCADE
# Referenced By:
#  nic_aws_resource | nic_aws_resource_aws_subnet_id_fkey | (aws_subnet_id) REFERENCES aws_subnet(id)
