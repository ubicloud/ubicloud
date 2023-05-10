# frozen_string_literal: true

require_relative "../model"

class MinioPool < Sequel::Model
  many_to_one :minio_cluster, key: :cluster_id
  one_to_many :minio_node, key: :pool_id
  one_to_one :strand, key: :id

  include SemaphoreMethods
  semaphore :destroy, :start
  def node_ipv6_sorted_by_creation
    minio_node_dataset.order_by(:created_at).eager(:vm).map { |n| n.vm.ephemeral_net6.to_s }
  end
end