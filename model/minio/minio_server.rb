# frozen_string_literal: true

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

  semaphore :destroy, :restart, :reconfigure

  def hostname
    "#{cluster.name}#{index}.#{Config.minio_host_name}"
  end

  def private_ipv4_address
    vm.nics.first.private_ipv4.network.to_s
  end

  def name
    "#{cluster.name}-#{pool.start_index}-#{index}"
  end

  def minio_volumes
    cluster.pools.map do |pool|
      pool.volumes_url
    end.join(" ")
  end

  def connection_string
    "http://#{vm.ephemeral_net4}:9000"
  end
end
