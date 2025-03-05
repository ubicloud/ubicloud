#  frozen_string_literal: true

require_relative "../model"

class LoadBalancerVmPort < Sequel::Model
  many_to_one :load_balancer_vm, class: LoadBalancersVms, key: :load_balancer_vm_id
  many_to_one :load_balancer_port
  include ResourceMethods
  include HealthMonitorMethods
end

# Table: load_balancer_vm_port
# Columns:
#  id                    | uuid                     | PRIMARY KEY
#  load_balancer_vm_id   | uuid                     | NOT NULL
#  load_balancer_port_id | uuid                     | NOT NULL
#  state                 | lb_node_state            | NOT NULL DEFAULT 'down'::lb_node_state
#  last_checked_at       | timestamp with time zone | NOT NULL DEFAULT CURRENT_TIMESTAMP
# Indexes:
#  load_balancer_vm_port_pkey | PRIMARY KEY btree (id)
#  lb_vm_port_unique_index    | UNIQUE btree (load_balancer_port_id, load_balancer_vm_id)
# Foreign key constraints:
#  load_balancer_vm_port_load_balancer_port_id_fkey | (load_balancer_port_id) REFERENCES load_balancer_port(id)
#  load_balancer_vm_port_load_balancer_vm_id_fkey   | (load_balancer_vm_id) REFERENCES load_balancers_vms(id) ON DELETE CASCADE
