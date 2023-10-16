# frozen_string_literal: true

require_relative "../../model"

class MinioPool < Sequel::Model
  many_to_one :minio_cluster, key: :cluster_id
  one_to_many :minio_servers, key: :minio_pool_id do |ds|
    ds.order(:index)
  end
  one_to_one :strand, key: :id

  include ResourceMethods
  include SemaphoreMethods
  include Authorization::HyperTagMethods
  include Authorization::TaggableMethods

  semaphore :restart, :destroy

  def hyper_tag_name(project)
    "project/#{project.ubid}/location/#{minio_cluster.location}/minio_pool/#{name}"
  end

  def volumes_url
    "http://#{servers_arg}.#{Config.minio_host_name}:9000#{drivers_arg}"
  end

  def servers_arg
    if minio_cluster.per_pool_server_count == 1
      "#{minio_cluster.name}#{start_index}"
    else
      "#{minio_cluster.name}{#{start_index}...#{minio_cluster.per_pool_server_count + start_index - 1}}"
    end
  end

  def drivers_arg
    if minio_cluster.per_pool_driver_count == minio_cluster.per_pool_server_count
      "/minio/dat1"
    else
      "/minio/dat{1...#{per_server_driver_count}}"
    end
  end

  def name
    "#{minio_cluster.name}-#{start_index}"
  end

  def per_server_driver_count
    (minio_cluster.per_pool_driver_count / minio_cluster.per_pool_server_count).to_i
  end

  def per_server_storage_size
    (minio_cluster.per_pool_storage_size / minio_cluster.per_pool_server_count).to_i
  end

  def waiting?
    strand.label == "wait"
  end
end
