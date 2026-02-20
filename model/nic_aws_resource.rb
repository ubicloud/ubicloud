# frozen_string_literal: true

require_relative "../model"

class NicAwsResource < Sequel::Model
  many_to_one :nic, key: :id, read_only: true, is_used: true
  plugin ResourceMethods
end

# Table: nic_aws_resource
# Columns:
#  id                   | uuid | PRIMARY KEY
#  eip_allocation_id    | text |
#  network_interface_id | text |
#  subnet_id            | text |
#  subnet_az            | text |
#  aws_subnet_id        | uuid |
# Indexes:
#  nic_aws_resource_pkey | PRIMARY KEY btree (id)
# Foreign key constraints:
#  nic_aws_resource_aws_subnet_id_fkey | (aws_subnet_id) REFERENCES aws_subnet(id)
#  nic_aws_resource_id_fkey            | (id) REFERENCES nic(id)
