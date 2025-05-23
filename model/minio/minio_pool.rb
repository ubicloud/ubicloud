# frozen_string_literal: true

require_relative "../../model"

class MinioPool < Sequel::Model
  many_to_one :cluster, class: :MinioCluster
  one_to_many :servers, key: :minio_pool_id, class: :MinioServer, order: :index
  one_to_one :strand, key: :id

  plugin ResourceMethods
  include SemaphoreMethods

  semaphore :destroy, :add_additional_pool

  def volumes_url
    return "/minio/dat1" if cluster.single_instance_single_drive?
    return "/minio/dat{1...#{drive_count}}" if cluster.single_instance_multi_drive?
    servers_arg = "#{cluster.name}{#{start_index}...#{server_count + start_index - 1}}"
    drivers_arg = "/minio/dat{1...#{per_server_drive_count}}"
    "https://#{servers_arg}.#{Config.minio_host_name}:9000#{drivers_arg}"
  end

  def name
    "#{cluster.name}-#{start_index}"
  end

  def per_server_drive_count
    (drive_count / server_count).to_i
  end

  def per_server_storage_size
    (storage_size_gib / server_count).to_i
  end
end

# Table: minio_pool
# Columns:
#  id               | uuid    | PRIMARY KEY
#  start_index      | integer | NOT NULL DEFAULT 0
#  cluster_id       | uuid    | NOT NULL
#  server_count     | integer |
#  drive_count      | integer |
#  storage_size_gib | bigint  |
#  vm_size          | text    | NOT NULL
# Indexes:
#  minio_pool_pkey | PRIMARY KEY btree (id)
# Foreign key constraints:
#  minio_pool_cluster_id_fkey | (cluster_id) REFERENCES minio_cluster(id)
# Referenced By:
#  minio_server | minio_server_minio_pool_id_fkey | (minio_pool_id) REFERENCES minio_pool(id)
