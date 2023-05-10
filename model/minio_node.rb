# frozen_string_literal: true

require_relative "../model"

class MinioNode < Sequel::Model
  many_to_one :minio_pool, key: :pool_id
  one_to_one :vm, key: :id
  one_to_one :sshable, key: :id

  include SemaphoreMethods
  semaphore :destroy

  def index
    @index ||= minio_pool.node_ipv6_sorted_by_creation.find_index { |n| n.start_with?(vm.ephemeral_net6.to_s) } + minio_pool.start_index
  end

  def good_address
    "#{minio_cluster.name}#{index}.#{Config.minio_host_name}"
  end

  def ipv6_addess
    vm.ephemeral_net6.to_s.split("/").first + "2"
  end

  def name
    minio_cluster.name + index.to_s
  end

  def minio_cluster
    minio_pool.minio_cluster
  end
end
