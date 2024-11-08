#  frozen_string_literal: true

require_relative "../model"

class LoadBalancersVms < Sequel::Model
  include ResourceMethods
end

# Table: load_balancers_vms
# Primary Key: (load_balancer_id, vm_id)
# Columns:
#  load_balancer_id | uuid          |
#  vm_id            | uuid          |
#  state            | lb_node_state | NOT NULL DEFAULT 'down'::lb_node_state
#  state_counter    | integer       | NOT NULL DEFAULT 0
# Indexes:
#  load_balancers_vms_pkey      | PRIMARY KEY btree (load_balancer_id, vm_id)
#  load_balancers_vms_vm_id_key | UNIQUE btree (vm_id)
# Foreign key constraints:
#  load_balancers_vms_load_balancer_id_fkey | (load_balancer_id) REFERENCES load_balancer(id)
#  load_balancers_vms_vm_id_fkey            | (vm_id) REFERENCES vm(id)
