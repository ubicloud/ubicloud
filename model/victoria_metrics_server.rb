# frozen_string_literal: true

require_relative "../model"

class VictoriaMetricsServer < Sequel::Model
  one_to_one :strand, key: :id
  many_to_one :vm
  many_to_one :resource, class: :VictoriaMetricsResource, key: :victoria_metrics_resource_id

  plugin ResourceMethods
  include SemaphoreMethods
  include HealthMonitorMethods

  semaphore :checkup, :destroy, :initial_provisioning, :restart, :reconfigure

  plugin :column_encryption do |enc|
    enc.column :cert_key
  end

  def public_ipv6_address
    vm.ip6.to_s
  end

  def private_ipv4_address
    vm.private_ipv4.to_s
  end

  def ip6_url
    "https://[#{public_ipv6_address}]:8427"
  end

  def endpoint
    (Config.development? || Config.is_e2e) ? ip6_url : "https://#{resource.hostname}:8427"
  end

  def init_health_monitor_session
    socket_path = File.join(Dir.pwd, "var", "health_monitor_sockets", "vn_#{vm.ephemeral_net6.nth(2)}")
    FileUtils.rm_rf(socket_path)
    FileUtils.mkdir_p(socket_path)

    ssh_session = vm.sshable.start_fresh_session
    ssh_session.forward.local(UNIXServer.new(File.join(socket_path, "health_monitor_socket")), private_ipv4_address, 8427)
    {
      ssh_session: ssh_session,
      victoria_metrics_client: client(socket: File.join("unix://", socket_path, "health_monitor_socket"))
    }
  end

  def check_pulse(session:, previous_pulse:)
    reading = begin
      session[:victoria_metrics_client].health ? "up" : "down"
    rescue
      "down"
    end
    pulse = aggregate_readings(previous_pulse: previous_pulse, reading: reading)

    if pulse[:reading] == "down" && pulse[:reading_rpt] > 5 && Time.now - pulse[:reading_chg] > 30 && !reload.checkup_set?
      incr_checkup
    end

    pulse
  end

  def needs_event_loop_for_pulse_check?
    true
  end

  def client(socket: nil)
    VictoriaMetrics::Client.new(
      endpoint: endpoint,
      ssl_ca_data: resource.root_certs + cert,
      socket: socket,
      username: resource.admin_user,
      password: resource.admin_password
    )
  end

  def self.redacted_columns
    super + [:cert]
  end
end

# Table: victoria_metrics_server
# Columns:
#  id                           | uuid                     | PRIMARY KEY
#  created_at                   | timestamp with time zone | NOT NULL DEFAULT now()
#  cert                         | text                     |
#  cert_key                     | text                     |
#  certificate_last_checked_at  | timestamp with time zone | NOT NULL DEFAULT now()
#  victoria_metrics_resource_id | uuid                     | NOT NULL
#  vm_id                        | uuid                     | NOT NULL
# Indexes:
#  victoria_metrics_server_pkey | PRIMARY KEY btree (id)
# Foreign key constraints:
#  victoria_metrics_server_victoria_metrics_resource_id_fkey | (victoria_metrics_resource_id) REFERENCES victoria_metrics_resource(id)
#  victoria_metrics_server_vm_id_fkey                        | (vm_id) REFERENCES vm(id)
