#  frozen_string_literal: true

require_relative "../model"

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

    stale_retry = false
    begin
      ((session[:ssh_session].exec!(health_check_cmd(type)).strip == "200") ? "up" : "down").tap { session[:last_pulse] = Time.now }
    rescue => e
      # "Staleness" of last_pulse should be somewhat less than
      # sshd_config ClientAlive setting.
      if !stale_retry &&
          (
            # Seen when sending on a broken connection.
            e.is_a?(IOError) && e.message == "closed stream" ||
            # Seen when receiving on a broken connection.
            e.is_a?(Errno::ECONNRESET) && e.message.start_with?("Connection reset by peer")
          ) &&
          session[:last_pulse]&.<(Time.now - 8)
        stale_retry = true
        session.merge!(init_health_monitor_session)
        retry
      end

      Clog.emit("Exception in LoadBalancerVmPort #{ubid}") { Util.exception_to_hash(e) }
      "down"
    end
  end

  def health_check_cmd(type)
    address = (type == :ipv4) ? vm.private_ipv4 : vm.ephemeral_net6.nth(2)
    if load_balancer.health_check_protocol == "tcp"
      "sudo ip netns exec #{vm.inhost_name} nc -z -w #{load_balancer.health_check_timeout} #{address} #{load_balancer_port.dst_port} >/dev/null 2>&1 && echo 200 || echo 400"
    else
      "sudo ip netns exec #{vm.inhost_name} curl --insecure --resolve #{load_balancer.hostname}:#{load_balancer_port.dst_port}:#{(address.version == 6) ? "[#{address}]" : address} --max-time #{load_balancer.health_check_timeout} --silent --output /dev/null --write-out '%{http_code}' #{load_balancer.health_check_protocol}://#{load_balancer.hostname}:#{load_balancer_port.dst_port}#{load_balancer.health_check_endpoint}"
    end
  end

  def check_pulse(session:, previous_pulse:)
    reading_ipv4, reading_ipv6 = health_check(session:)
    reading = (reading_ipv4 == "up" && reading_ipv6 == "up") ? "up" : "down"
    pulse = aggregate_readings(previous_pulse:, reading:, data: {ipv4: reading_ipv4, ipv6: reading_ipv6})

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
