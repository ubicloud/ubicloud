# frozen_string_literal: true

require_relative "../../model"

class MinioServer < Sequel::Model
  one_to_one :strand, key: :id
  many_to_one :project
  many_to_one :vm, key: :vm_id, class: :Vm
  one_to_many :active_billing_records, class: :BillingRecord, key: :resource_id, conditions: {Sequel.function(:upper, :span) => nil}
  many_to_one :minio_pool, key: :minio_pool_id

  include ResourceMethods
  include SemaphoreMethods
  include Authorization::HyperTagMethods
  include Authorization::TaggableMethods

  semaphore :restart, :destroy, :minio_start

  def hyper_tag_name(project)
    "project/#{project.ubid}/location/#{minio_cluster.location}/minio_server/#{name}"
  end

  def hostname
    "#{minio_cluster.name}#{index}.#{Config.minio_host_name}"
  end

  def private_ipv4_address
    vm.nics.first.private_ipv4.network.to_s
  end

  def name
    "#{minio_cluster.name}-#{minio_pool.start_index}-#{index}"
  end

  # YYY: handle this via join table
  def minio_cluster
    minio_pool.minio_cluster
  end

  def minio_volumes
    return "/minio/dat1" if minio_cluster.target_total_server_count == 1 && minio_cluster.target_total_driver_count == 1
    return "/minio/dat{1...#{minio_cluster.target_total_driver_count}}" if minio_cluster.target_total_server_count == 1
    minio_cluster.minio_pools.map do |pool|
      pool.volumes_url
    end.join(" ")
  end

  def waiting?
    strand.label == "wait"
  end
end
