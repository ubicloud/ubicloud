# frozen_string_literal: true

require_relative "../model"

class ParseableServer < Sequel::Model
  one_to_one :strand, key: :id
  many_to_one :vm, read_only: true
  many_to_one :resource, class: :ParseableResource, key: :parseable_resource_id, read_only: true

  plugin ResourceMethods, redacted_columns: :cert, encrypted_columns: :cert_key
  plugin SemaphoreMethods, :checkup, :destroy, :initial_provisioning, :restart, :reconfigure, :configure_metrics
  include HealthMonitorMethods
  include MetricsTargetMethods

  def public_ipv6_address
    vm.ip6_string
  end

  def ip6_url
    "https://[#{public_ipv6_address}]:8000"
  end

  def endpoint
    (Config.development? || Config.is_e2e) ? ip6_url : "https://#{resource.hostname}:8000"
  end

  def init_health_monitor_session
    {parseable_client: client}
  end

  def init_metrics_export_session
    {ssh_session: vm.sshable.start_fresh_session}
  end

  def metrics_config
    {
      endpoints: [
        {url: "https://localhost:8000/api/v1/metrics", username: resource.admin_user, password: resource.admin_password},
        "http://localhost:9100/metrics",
      ],
      max_file_retention: 120,
      interval: "15s",
      additional_labels: {ubicloud_resource_id: resource.ubid, instance: ubid},
      metrics_dir: "/home/ubi/parseable/metrics",
      project_id: Config.postgres_service_project_id,
      exclude_metrics: ["[{,]stream=\""],
    }
  end

  def check_pulse(session:, previous_pulse:)
    reading = begin
      session[:parseable_client].healthy? ? "up" : "down"
    rescue
      "down"
    end
    pulse = aggregate_readings(previous_pulse:, reading:)

    if pulse[:reading] == "down" && pulse[:reading_rpt] > 5 && Time.now - pulse[:reading_chg] > 30 && !reload.checkup_set?
      incr_checkup
    end

    pulse
  end

  def client
    Parseable::Client.new(
      endpoint:,
      ssl_ca_data: resource.root_certs,
      username: resource.admin_user,
      password: resource.admin_password,
    )
  end
end

# Table: parseable_server
# Columns:
#  id                          | uuid                     | PRIMARY KEY DEFAULT gen_random_ubid_uuid(718)
#  created_at                  | timestamp with time zone | NOT NULL DEFAULT CURRENT_TIMESTAMP
#  cert                        | text                     |
#  cert_key                    | text                     |
#  certificate_last_checked_at | timestamp with time zone | NOT NULL DEFAULT CURRENT_TIMESTAMP
#  parseable_resource_id       | uuid                     | NOT NULL
#  vm_id                       | uuid                     | NOT NULL
# Indexes:
#  parseable_server_pkey | PRIMARY KEY btree (id)
# Foreign key constraints:
#  parseable_server_parseable_resource_id_fkey | (parseable_resource_id) REFERENCES parseable_resource(id)
#  parseable_server_vm_id_fkey                 | (vm_id) REFERENCES vm(id)
