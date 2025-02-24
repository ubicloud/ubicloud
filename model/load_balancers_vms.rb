#  frozen_string_literal: true

require_relative "../model"

class LoadBalancersVms < Sequel::Model
  many_to_one :load_balancer
  many_to_one :vm
  include ResourceMethods
  include HealthMonitorMethods
end

# Table: load_balancers_vms
# Columns:
#  load_balancer_id | uuid | NOT NULL
#  vm_id            | uuid | NOT NULL
#  id               | uuid | PRIMARY KEY
# Indexes:
#  load_balancers_vms_pkey      | PRIMARY KEY btree (id)
#  load_balancers_vms_vm_id_key | UNIQUE btree (vm_id)
# Foreign key constraints:
#  load_balancers_vms_load_balancer_id_fkey | (load_balancer_id) REFERENCES load_balancer(id)
#  load_balancers_vms_vm_id_fkey            | (vm_id) REFERENCES vm(id)
