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

  include ResourceMethods
  include SemaphoreMethods
  include Authorization::HyperTagMethods
  include Authorization::TaggableMethods

  semaphore :destroy, :reconfigure

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

  def per_pool_drive_count
    (target_total_drive_count / target_total_pool_count).to_i
  end

  def connection_strings
    servers.map { "http://#{_1.vm.ephemeral_net4}:9000" }
  end

  def hostname
    "#{name}.#{Config.minio_host_name}"
  end
end
