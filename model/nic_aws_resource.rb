# frozen_string_literal: true

require_relative "../model"

class NicAwsResource < Sequel::Model
  many_to_one :nic, key: :id

  plugin ResourceMethods
end

# Table: nic_aws_resource
# Columns:
#  id                   | uuid | PRIMARY KEY
#  eip_allocation_id    | text |
#  network_interface_id | text |
#  subnet_id            | text |
#  subnet_az            | text |
# Indexes:
#  nic_aws_resource_pkey | PRIMARY KEY btree (id)
# Foreign key constraints:
#  nic_aws_resource_id_fkey | (id) REFERENCES nic(id)
