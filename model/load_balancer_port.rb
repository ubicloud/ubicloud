#  frozen_string_literal: true

require_relative "../model"

class LoadBalancerPort < Sequel::Model
  many_to_one :load_balancer
  plugin ResourceMethods
  include HealthMonitorMethods
end

# Table: load_balancer_port
# Columns:
#  id               | uuid    | PRIMARY KEY
#  load_balancer_id | uuid    | NOT NULL
#  src_port         | integer | NOT NULL
#  dst_port         | integer | NOT NULL
# Indexes:
#  load_balancer_port_pkey | PRIMARY KEY btree (id)
#  lb_port_unique_index    | UNIQUE btree (load_balancer_id, src_port)
# Check constraints:
#  dst_port_range | (dst_port >= 1 AND dst_port <= 65535)
#  src_port_range | (src_port >= 1 AND src_port <= 65535)
# Foreign key constraints:
#  load_balancer_port_load_balancer_id_fkey | (load_balancer_id) REFERENCES load_balancer(id)
# Referenced By:
#  load_balancer_vm_port | load_balancer_vm_port_load_balancer_port_id_fkey | (load_balancer_port_id) REFERENCES load_balancer_port(id)
