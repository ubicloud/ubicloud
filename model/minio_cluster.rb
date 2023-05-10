# frozen_string_literal: true

require_relative "../model"

class MinioCluster < Sequel::Model
  one_to_many :minio_pool, key: :cluster_id
  one_to_one :strand, key: :id

  include SemaphoreMethods
  semaphore :destroy

  def generate_etc_hosts_entry
    minio_pool.map do |pool|
      pool.minio_node.map do |node|
        "#{node.ipv6_addess} #{node.good_address}"
      end.join("\n")
    end.join("\n")
  end

  def minio_node
    minio_pool.map(&:minio_node).flatten
  end
end
