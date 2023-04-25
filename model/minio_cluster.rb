# frozen_string_literal: true

require_relative "../model"

class MinioCluster < Sequel::Model
  one_to_many :minio_node, key: :cluster_id

  def node_ipv6_sorted_by_creation
    minio_node.sort_by{ |n| n.created_at }.map{ |n| n.vm.ephemeral_net6.to_s }
  end

  def admin_pass

  end
end
