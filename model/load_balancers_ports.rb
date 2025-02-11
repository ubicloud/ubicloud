#  frozen_string_literal: true

require_relative "../model"

class LoadBalancersPorts < Sequel::Model
  many_to_one :load_balancer
  include ResourceMethods
  include HealthMonitorMethods
end

# Table: load_balancers_ports
# Columns:
#  id                          | uuid    | PRIMARY KEY DEFAULT gen_random_uuid()
#  load_balancer_id            | uuid    |
#  src_port                    | integer | NOT NULL
#  dst_port                    | integer | NOT NULL
#  health_check_endpoint       | text    | NOT NULL DEFAULT '/up'::text
#  health_check_interval       | integer | NOT NULL DEFAULT 30
#  health_check_timeout        | integer | NOT NULL DEFAULT 15
#  health_check_up_threshold   | integer | NOT NULL DEFAULT 3
#  health_check_down_threshold | integer | NOT NULL DEFAULT 2
#  health_check_protocol       | text    | NOT NULL DEFAULT 'http'::text
# Indexes:
#  load_balancers_ports_pkey                                     | PRIMARY KEY btree (id)
#  load_balancers_ports_load_balancer_id_src_port_dst_port_index | UNIQUE btree (load_balancer_id, src_port, dst_port)
# Check constraints:
#  load_balancers_ports_check                             | (health_check_timeout <= health_check_interval)
#  load_balancers_ports_health_check_down_threshold_check | (health_check_down_threshold > 0)
#  load_balancers_ports_health_check_interval_check       | (health_check_interval > 0)
#  load_balancers_ports_health_check_interval_check1      | (health_check_interval < 600)
#  load_balancers_ports_health_check_timeout_check        | (health_check_timeout > 0)
#  load_balancers_ports_health_check_up_threshold_check   | (health_check_up_threshold > 0)
# Foreign key constraints:
#  load_balancers_ports_load_balancer_id_fkey | (load_balancer_id) REFERENCES load_balancer(id) ON DELETE CASCADE
