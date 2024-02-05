# frozen_string_literal: true

require "net/ssh"
require_relative "../../model"

class MinioServer < Sequel::Model
  one_to_one :strand, key: :id
  many_to_one :project
  many_to_one :vm, key: :vm_id, class: :Vm
  one_to_many :active_billing_records, class: :BillingRecord, key: :resource_id, conditions: {Sequel.function(:upper, :span) => nil}
  many_to_one :pool, key: :minio_pool_id, class: :MinioPool
  one_through_many :cluster, [[:minio_server, :id, :minio_pool_id], [:minio_pool, :id, :cluster_id]], class: :MinioCluster

  dataset_module Authorization::Dataset

  include ResourceMethods
  include SemaphoreMethods
  include HealthMonitorMethods

  semaphore :checkup, :destroy, :restart, :reconfigure

  def hostname
    "#{cluster.name}#{index}.#{Config.minio_host_name}"
  end

  def private_ipv4_address
    vm.nics.first.private_ipv4.network.to_s
  end

  def minio_volumes
    cluster.pools.map do |pool|
      pool.volumes_url
    end.join(" ")
  end

  def ip4_url
    "http://#{vm.ephemeral_net4}:9000"
  end

  def endpoint
    cluster.dns_zone ? "#{hostname}:9000" : "#{vm.ephemeral_net4}:9000"
  end

  def init_health_monitor_session
    socket_path = File.join(Dir.pwd, "health_monitor_sockets", "ms_#{vm.ephemeral_net6.nth(2)}")
    FileUtils.rm_rf(socket_path)
    FileUtils.mkdir_p(socket_path)

    ssh_session = vm.sshable.start_fresh_session
    ssh_session.forward.local(UNIXServer.new(File.join(socket_path, "health_monitor_socket")), private_ipv4_address, 9000)
    {
      ssh_session: ssh_session,
      minio_client: Minio::Client.new(
        endpoint: ip4_url,
        access_key: cluster.admin_user,
        secret_key: cluster.admin_password,
        socket: File.join(socket_path, "health_monitor_socket")
      )
    }
  end

  def check_pulse(session:, previous_pulse:)
    reading = begin
      server_data = JSON.parse(session[:minio_client].admin_info.body)["servers"].find { _1["endpoint"] == endpoint }
      (server_data["state"] == "online" && server_data["drives"].all? { _1["state"] == "ok" }) ? "up" : "down"
    rescue
      "down"
    end
    pulse = aggregate_readings(previous_pulse: previous_pulse, reading: reading)

    if pulse[:reading] == "down" && pulse[:reading_rpt] > 5 && Time.now - pulse[:reading_chg] > 30
      incr_checkup
    end

    pulse
  end

  def server_url
    cluster.url || ip4_url
  end
end
