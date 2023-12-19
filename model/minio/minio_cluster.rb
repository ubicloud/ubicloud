# frozen_string_literal: true

require_relative "../../model"

class MinioCluster < Sequel::Model
  one_to_many :pools, key: :cluster_id, class: :MinioPool do |ds|
    ds.order(:start_index)
  end
  many_through_many :servers, [[:minio_pool, :cluster_id, :id], [:minio_server, :minio_pool_id, :id]], class: :MinioServer do |ds|
    ds.order(:index)
  end
  one_to_one :strand, key: :id
  many_to_one :private_subnet, key: :private_subnet_id
  one_to_one :monitorable, key: :id

  include ResourceMethods
  include SemaphoreMethods
  include Authorization::HyperTagMethods
  include Authorization::TaggableMethods

  semaphore :destroy

  plugin :column_encryption do |enc|
    enc.column :admin_password
  end

  def hyper_tag_name(project)
    "project/#{project.ubid}/location/#{location}/minio-cluster/#{name}"
  end

  def generate_etc_hosts_entry
    servers.map do |server|
      "#{server.private_ipv4_address} #{server.hostname}"
    end.join("\n")
  end

  def per_pool_storage_size
    (target_total_storage_size_gib / target_total_pool_count).to_i
  end

  def per_pool_server_count
    (target_total_server_count / target_total_pool_count).to_i
  end

  def per_pool_driver_count
    (target_total_driver_count / target_total_pool_count).to_i
  end

  def connection_strings
    servers.map { "http://#{_1.vm.ephemeral_net4}:9000" }
  end

  def hostname
    "#{name}.#{Config.minio_host_name}"
  end

  def init_health_monitor_session
    Minio::Client.new(
      endpoint: connection_strings.first,
      access_key: admin_user,
      secret_key: admin_password
    )
  end

  def check_health_status(session:)
    reading = begin
      JSON.parse(session.admin_info.body)["servers"].map { _1["state"] }.all?("online") ? "up" : "down"
    rescue
      "down"
    end

    status = {
      reading: reading,
      reading_rpt: (monitorable.status["reading"] == reading) ? monitorable.status["reading_rpt"] + 1 : 1,
      reading_chg: (monitorable.status["reading"] == reading) ? monitorable.status["reading_chg"] : Time.now
    }
    monitorable.update(status: status)

    if status["reading"] == "down" && status["reading_rpt"] > 5 && Time.now - Time.parse(status["reading_chg"]) > 30
      Prog::PageNexus.assemble("#{ubid} is unavailable!", [ubid], "MinIOClusterUnavailable", id)
    end
  end
end
