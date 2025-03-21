#  frozen_string_literal: true

require_relative "../model"

class LoadBalancersVms < Sequel::Model
  many_to_one :load_balancer
  many_to_one :vm
  include ResourceMethods
  include HealthMonitorMethods

  def init_health_monitor_session
    {
      ssh_session: vm.vm_host.sshable.start_fresh_session
    }
  end

  def health_check(session:)
    [
      check_probe(session, :ipv4),
      check_probe(session, :ipv6)
    ]
  end

  def check_probe(session, type)
    if type == :ipv4
      return "up" unless load_balancer.ipv4_enabled?
    elsif type == :ipv6
      return "up" unless load_balancer.ipv6_enabled?
    else
      raise "Invalid type: #{type}"
    end

    begin
      (session[:ssh_session].exec!(health_check_cmd(type)).strip == "200") ? "up" : "down"
    rescue
      "down"
    end
  end

  def health_check_cmd(type)
    address = (type == :ipv4) ? vm.private_ipv4 : vm.ephemeral_net6.nth(2)
    if load_balancer.health_check_protocol == "tcp"
      "sudo ip netns exec #{vm.inhost_name} nc -z -w #{load_balancer.health_check_timeout} #{address} #{load_balancer.dst_port} >/dev/null 2>&1 && echo 200 || echo 400"
    else
      "sudo ip netns exec #{vm.inhost_name} curl --insecure --resolve #{load_balancer.hostname}:#{load_balancer.dst_port}:#{(address.version == 6) ? "[#{address}]" : address} --max-time #{load_balancer.health_check_timeout} --silent --output /dev/null --write-out '%{http_code}' #{load_balancer.health_check_protocol}://#{load_balancer.hostname}:#{load_balancer.dst_port}#{load_balancer.health_check_endpoint}"
    end
  end

  def check_pulse(session:, previous_pulse:)
    reading_ipv4, reading_ipv6 = health_check(session:)
    reading = (reading_ipv4 == "up" && reading_ipv6 == "up") ? "up" : "down"
    pulse = aggregate_readings(previous_pulse:, reading:, data: {ipv4: reading_ipv4, ipv6: reading_ipv6})

    if state == "up" && pulse[:reading] == "down" && (pulse[:reading_rpt] > load_balancer.health_check_down_threshold && Time.now - pulse[:reading_chg] > load_balancer.health_check_interval) && !load_balancer.reload.update_load_balancer_set?
      update(state: "down")
      load_balancer.incr_update_load_balancer
    end

    if state == "down" && pulse[:reading] == "up" && (pulse[:reading_rpt] > load_balancer.health_check_up_threshold && Time.now - pulse[:reading_chg] > load_balancer.health_check_interval) && !load_balancer.reload.update_load_balancer_set?
      update(state: "up")
      load_balancer.incr_update_load_balancer
    end

    pulse
  end
end

# Table: load_balancers_vms
# Columns:
#  load_balancer_id | uuid          | NOT NULL
#  vm_id            | uuid          | NOT NULL
#  state            | lb_node_state | NOT NULL DEFAULT 'down'::lb_node_state
#  id               | uuid          | PRIMARY KEY
# Indexes:
#  load_balancers_vms_pkey      | PRIMARY KEY btree (id)
#  load_balancers_vms_vm_id_key | UNIQUE btree (vm_id)
# Foreign key constraints:
#  load_balancers_vms_load_balancer_id_fkey | (load_balancer_id) REFERENCES load_balancer(id)
#  load_balancers_vms_vm_id_fkey            | (vm_id) REFERENCES vm(id)
