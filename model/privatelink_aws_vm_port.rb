# frozen_string_literal: true

require_relative "../model"

class PrivatelinkAwsVmPort < Sequel::Model
  many_to_one :privatelink_aws_vm
  many_to_one :privatelink_aws_port

  plugin ResourceMethods

  def vm
    privatelink_aws_vm.vm
  end

  def privatelink_aws_resource
    privatelink_aws_port.privatelink_aws_resource
  end
end

# Table: privatelink_aws_vm_port
# Columns:
#  id                         | uuid                     | PRIMARY KEY
#  created_at                 | timestamp with time zone | NOT NULL DEFAULT now()
#  privatelink_aws_vm_id      | uuid                     | NOT NULL
#  privatelink_aws_port_id    | uuid                     | NOT NULL
#  state                      | text                     | NOT NULL DEFAULT 'registering'
# Indexes:
#  privatelink_aws_vm_port_pkey       | PRIMARY KEY btree (id)
#  pl_vm_port_unique_idx              | UNIQUE btree (privatelink_aws_vm_id, privatelink_aws_port_id)
# Check constraints:
#  state_check | (state IN ('registering', 'registered', 'deregistering', 'deregistered'))
# Foreign key constraints:
#  privatelink_aws_vm_port_privatelink_aws_port_id_fkey | (privatelink_aws_port_id) REFERENCES privatelink_aws_port(id) ON DELETE CASCADE
#  privatelink_aws_vm_port_privatelink_aws_vm_id_fkey   | (privatelink_aws_vm_id) REFERENCES privatelink_aws_vm(id) ON DELETE CASCADE
