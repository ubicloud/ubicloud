#  frozen_string_literal: true

require_relative "../model"

class LoadBalancerPort < Sequel::Model
  many_to_one :load_balancer
  include ResourceMethods
  include HealthMonitorMethods
end

# Table: load_balancer_port
# Columns:
#  id                          | uuid    | PRIMARY KEY
#  load_balancer_id            | uuid    | NOT NULL
#  src_port                    | integer | NOT NULL
#  dst_port                    | integer | NOT NULL
#  health_check_endpoint       | text    | NOT NULL DEFAULT '/up'::text
#  health_check_interval       | integer | NOT NULL DEFAULT 30
#  health_check_timeout        | integer | NOT NULL DEFAULT 15
#  health_check_up_threshold   | integer | NOT NULL DEFAULT 3
#  health_check_down_threshold | integer | NOT NULL DEFAULT 2
#  health_check_protocol       | text    | NOT NULL DEFAULT 'http'::text
# Indexes:
#  load_balancer_port_pkey | PRIMARY KEY btree (id)
#  lb_port_unique_index    | UNIQUE btree (load_balancer_id, src_port, dst_port)
# Check constraints:
#  load_balancer_port_check                             | (health_check_timeout <= health_check_interval)
#  load_balancer_port_health_check_down_threshold_check | (health_check_down_threshold > 0)
#  load_balancer_port_health_check_interval_check       | (health_check_interval > 0 AND health_check_interval < 600)
#  load_balancer_port_health_check_timeout_check        | (health_check_timeout > 0)
#  load_balancer_port_health_check_up_threshold_check   | (health_check_up_threshold > 0)
# Foreign key constraints:
#  load_balancer_port_load_balancer_id_fkey | (load_balancer_id) REFERENCES load_balancer(id)
# Referenced By:
#  load_balancer_vm_port | load_balancer_vm_port_load_balancer_port_id_fkey | (load_balancer_port_id) REFERENCES load_balancer_port(id)
