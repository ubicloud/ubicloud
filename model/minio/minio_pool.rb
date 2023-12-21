# frozen_string_literal: true

require_relative "../../model"

class MinioPool < Sequel::Model
  many_to_one :cluster, key: :cluster_id, class: :MinioCluster
  one_to_many :servers, key: :minio_pool_id, class: :MinioServer do |ds|
    ds.order(:index)
  end
  one_to_one :strand, key: :id

  include ResourceMethods
  include SemaphoreMethods

  semaphore :destroy

  def volumes_url
    servers_arg = "#{cluster.name}{#{start_index}...#{cluster.per_pool_server_count + start_index - 1}}"
    drivers_arg = "/minio/dat{1...#{per_server_drive_count}}"
    "http://#{servers_arg}.#{Config.minio_host_name}:9000#{drivers_arg}"
  end

  def name
    "#{cluster.name}-#{start_index}"
  end

  def per_server_drive_count
    (cluster.per_pool_drive_count / cluster.per_pool_server_count).to_i
  end

  def per_server_storage_size
    (cluster.per_pool_storage_size / cluster.per_pool_server_count).to_i
  end
end
