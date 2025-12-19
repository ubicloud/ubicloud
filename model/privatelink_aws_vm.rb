# frozen_string_literal: true

require_relative "../model"

class PrivatelinkAwsVm < Sequel::Model(:privatelink_aws_vm)
  many_to_one :privatelink_aws_resource
  many_to_one :vm
  one_to_many :vm_ports, class: :PrivatelinkAwsVmPort, key: :privatelink_aws_vm_id

  plugin ResourceMethods
end

# Table: privatelink_aws_vm
# Columns:
#  id                            | uuid                     | PRIMARY KEY
#  created_at                    | timestamp with time zone | NOT NULL DEFAULT now()
#  privatelink_aws_resource_id   | uuid                     | NOT NULL
#  vm_id                         | uuid                     | NOT NULL
# Indexes:
#  privatelink_aws_vm_pkey              | PRIMARY KEY btree (id)
#  pl_vm_unique_idx                     | UNIQUE btree (privatelink_aws_resource_id, vm_id)
# Foreign key constraints:
#  privatelink_aws_vm_privatelink_aws_resource_id_fkey | (privatelink_aws_resource_id) REFERENCES privatelink_aws_resource(id) ON DELETE CASCADE
#  privatelink_aws_vm_vm_id_fkey                       | (vm_id) REFERENCES vm(id)
