#  frozen_string_literal: true

require_relative "../model"
require_relative "../lib/net_ssh"

class LoadBalancerVmPort < Sequel::Model
  many_to_one :load_balancer_vm
  many_to_one :load_balancer_port
  plugin ResourceMethods
  include HealthMonitorMethods

  def load_balancer
    load_balancer_port.load_balancer
  end

  def vm
    load_balancer_vm.vm
  end

  def init_health_monitor_session
    {
      ssh_session: vm.vm_host.sshable.start_fresh_session
    }
  end

  def check_probe(session, type)
    if type == :ipv4
      raise "This entity should not exist: #{ubid}" unless load_balancer.ipv4_enabled?
    elsif type == :ipv6
      raise "This entity should not exist: #{ubid}" unless load_balancer.ipv6_enabled?
    else
      raise "Invalid type: #{type}"
    end

    begin
      (session[:ssh_session].exec!(health_check_cmd(type)).strip == "200") ? "up" : "down"
    rescue IOError, Errno::ECONNRESET
      raise
    rescue => e
      Clog.emit("Exception in LoadBalancerVmPort #{ubid}") { Util.exception_to_hash(e) }
      "down"
    end
  end

  def health_check_cmd(type)
    address = (type == :ipv4) ? vm.private_ipv4 : vm.ip6
    if load_balancer.health_check_protocol == "tcp"
      "sudo ip netns exec #{vm.inhost_name} nc -z -w #{load_balancer.health_check_timeout} #{address} #{load_balancer_port.dst_port} >/dev/null 2>&1 && echo 200 || echo 400"
    else
      "sudo ip netns exec #{vm.inhost_name} curl --insecure --resolve #{load_balancer.hostname}:#{load_balancer_port.dst_port}:#{(address.version == 6) ? "[#{address}]" : address} --max-time #{load_balancer.health_check_timeout} --silent --output /dev/null --write-out '%{http_code}' #{load_balancer.health_check_url(use_endpoint: true).shellescape}"
    end
  end

  def check_pulse(session:, previous_pulse:)
    reading = check_probe(session, stack.to_sym)
    pulse = aggregate_readings(previous_pulse:, reading:)

    time_passed_health_check_interval = Time.now - pulse[:reading_chg] > load_balancer.health_check_interval

    if state == "up" && pulse[:reading] == "down" && pulse[:reading_rpt] > load_balancer.health_check_down_threshold && time_passed_health_check_interval && !load_balancer.reload.update_load_balancer_set?
      update(state: "down")
      load_balancer.incr_update_load_balancer
    end

    if state == "down" && pulse[:reading] == "up" && pulse[:reading_rpt] > load_balancer.health_check_up_threshold && time_passed_health_check_interval && !load_balancer.reload.update_load_balancer_set?
      update(state: "up")
      load_balancer.incr_update_load_balancer
    end

    pulse
  end
end

# Table: load_balancer_vm_port
# Columns:
#  id                    | uuid                     | PRIMARY KEY DEFAULT gen_random_ubid_uuid(55)
#  load_balancer_vm_id   | uuid                     | NOT NULL
#  load_balancer_port_id | uuid                     | NOT NULL
#  state                 | lb_node_state            | NOT NULL DEFAULT 'down'::lb_node_state
#  last_checked_at       | timestamp with time zone | NOT NULL DEFAULT CURRENT_TIMESTAMP
#  stack                 | text                     | NOT NULL
# Indexes:
#  load_balancer_vm_port_pkey    | PRIMARY KEY btree (id)
#  lb_vm_port_stack_unique_index | UNIQUE btree (load_balancer_port_id, load_balancer_vm_id, stack)
# Check constraints:
#  stack_check | (stack = ANY (ARRAY['ipv4'::text, 'ipv6'::text]))
# Foreign key constraints:
#  load_balancer_vm_port_load_balancer_port_id_fkey | (load_balancer_port_id) REFERENCES load_balancer_port(id)
#  load_balancer_vm_port_load_balancer_vm_id_fkey   | (load_balancer_vm_id) REFERENCES load_balancers_vms(id) ON DELETE CASCADE
