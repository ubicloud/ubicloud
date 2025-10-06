# frozen_string_literal: true

require "net/ssh"
require_relative "../../model"

class MinioServer < Sequel::Model
  one_to_one :strand, key: :id
  many_to_one :vm
  one_to_many :active_billing_records, class: :BillingRecord, key: :resource_id, conditions: {Sequel.function(:upper, :span) => nil}
  many_to_one :pool, key: :minio_pool_id, class: :MinioPool
  one_through_one :cluster, join_table: :minio_pool, left_primary_key: :minio_pool_id, left_key: :id, class: :MinioCluster

  plugin ResourceMethods, redacted_columns: :cert, encrypted_columns: :cert_key
  plugin SemaphoreMethods, :checkup, :destroy, :restart, :reconfigure, :refresh_certificates, :initial_provisioning
  include HealthMonitorMethods

  def generate_etc_hosts_entry
    entries = ["127.0.0.1 #{hostname}"]
    entries += cluster.servers.reject { it.id == id }.map do |server|
      "#{server.public_ipv4_address} #{server.hostname}"
    end
    entries.join("\n")
  end

  def hostname
    "#{cluster.name}#{index}.#{Config.minio_host_name}"
  end

  def private_ipv4_address
    vm.private_ipv4.to_s
  end

  def public_ipv4_address
    vm.ip4.to_s
  end

  def minio_volumes
    cluster.pools.map do |pool|
      pool.volumes_url
    end.join(" ")
  end

  def ip4_url
    "https://#{public_ipv4_address}:9000"
  end

  def endpoint
    cluster.dns_zone ? "#{hostname}:9000" : "#{public_ipv4_address}:9000"
  end

  def init_health_monitor_session
    socket_path = File.join(Dir.pwd, "var", "health_monitor_sockets", "ms_#{public_ipv4_address}")
    FileUtils.rm_rf(socket_path)
    FileUtils.mkdir_p(socket_path)

    ssh_session = vm.sshable.start_fresh_session
    ssh_session.forward.local(UNIXServer.new(File.join(socket_path, "health_monitor_socket")), private_ipv4_address, 9000)
    {
      ssh_session: ssh_session,
      minio_client: client(socket: File.join("unix://", socket_path, "health_monitor_socket"))
    }
  end

  def server_data(client = self.client)
    server_data = JSON.parse(client.admin_info.body)["servers"]
    if cluster.server_count == 1
      server_data.first
    else
      server_data.find { it["endpoint"] == endpoint }
    end
  end

  def check_pulse(session:, previous_pulse:)
    reading = begin
      server_data = self.server_data(session[:minio_client])
      (server_data["state"] == "online" && server_data["drives"].all? { it["state"] == "ok" }) ? "up" : "down"
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

  def server_url
    cluster.url || ip4_url
  end

  def client(socket: nil)
    Minio::Client.new(
      endpoint: server_url,
      access_key: cluster.admin_user,
      secret_key: cluster.admin_password,
      ssl_ca_data: cluster.root_certs,
      socket: socket
    )
  end
end

# Table: minio_server
# Columns:
#  id                          | uuid                     | PRIMARY KEY
#  index                       | integer                  | NOT NULL
#  minio_pool_id               | uuid                     |
#  vm_id                       | uuid                     | NOT NULL
#  cert                        | text                     |
#  cert_key                    | text                     |
#  certificate_last_checked_at | timestamp with time zone | NOT NULL DEFAULT now()
# Indexes:
#  minio_server_pkey | PRIMARY KEY btree (id)
# Foreign key constraints:
#  minio_server_minio_pool_id_fkey | (minio_pool_id) REFERENCES minio_pool(id)
#  minio_server_vm_id_fkey         | (vm_id) REFERENCES vm(id)
