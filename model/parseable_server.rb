# frozen_string_literal: true

require_relative "../model"

class ParseableServer < Sequel::Model
  one_to_one :strand, key: :id
  many_to_one :vm
  many_to_one :resource, class: :ParseableResource, key: :parseable_resource_id

  plugin ResourceMethods, redacted_columns: :cert, encrypted_columns: :cert_key
  plugin SemaphoreMethods, :checkup, :destroy, :initial_provisioning, :restart, :reconfigure
  include HealthMonitorMethods

  def public_ipv6_address
    vm.ip6_string
  end

  def private_ipv4_address
    vm.private_ipv4.to_s
  end

  def ip6_url
    "https://[#{public_ipv6_address}]:8000"
  end

  def endpoint
    (Config.development? || Config.is_e2e) ? ip6_url : "https://#{resource.hostname}:8000"
  end

  def init_health_monitor_session
    socket_path = File.join(Dir.pwd, "var", "health_monitor_sockets", "pn_#{vm.ip6}")
    FileUtils.rm_rf(socket_path)
    FileUtils.mkdir_p(socket_path)

    ssh_session = vm.sshable.start_fresh_session
    ssh_session.forward.local(UNIXServer.new(File.join(socket_path, "health_monitor_socket")), private_ipv4_address, 8000)
    {
      ssh_session:,
      parseable_client: client(socket: File.join("unix://", socket_path, "health_monitor_socket"))
    }
  end

  def check_pulse(session:, previous_pulse:)
    reading = begin
      session[:parseable_client].health ? "up" : "down"
    rescue
      "down"
    end
    pulse = aggregate_readings(previous_pulse:, reading:)

    if pulse[:reading] == "down" && pulse[:reading_rpt] > 5 && Time.now - pulse[:reading_chg] > 30 && !reload.checkup_set?
      incr_checkup
    end

    pulse
  end

  def needs_event_loop_for_pulse_check?
    true
  end

  def client(socket: nil)
    Parseable::Client.new(
      endpoint:,
      ssl_ca_data: resource.root_certs,
      socket:,
      username: resource.admin_user,
      password: resource.admin_password
    )
  end
end

# Table: parseable_server
# Columns:
#  id                      | uuid                     | PRIMARY KEY
#  created_at              | timestamp with time zone | NOT NULL DEFAULT now()
#  cert                    | text                     |
#  cert_key                | text                     |
#  certificate_last_checked_at | timestamp with time zone | NOT NULL DEFAULT now()
#  parseable_resource_id   | uuid                     | NOT NULL
#  vm_id                   | uuid                     | NOT NULL
# Indexes:
#  parseable_server_pkey | PRIMARY KEY btree (id)
# Foreign key constraints:
#  parseable_server_parseable_resource_id_fkey | (parseable_resource_id) REFERENCES parseable_resource(id)
#  parseable_server_vm_id_fkey                 | (vm_id) REFERENCES vm(id)
