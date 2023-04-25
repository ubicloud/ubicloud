# frozen_string_literal: true

require_relative "../model"

class MinioNode < Sequel::Model
    many_to_one :vm
    one_to_one :strand, key: :id
    one_to_one :sshable, key: :id
    many_to_one :minio_cluster, key: :cluster_id, class: MinioCluster

    include SemaphoreMethods
    semaphore :destroy, :start_node

    def generate_etc_hosts_entry
      minio_cluster.node_ipv6_sorted_by_creation.map.with_index(1) do |ipv6, i|
        "#{ipv6.split("/").first} #{minio_cluster.name}#{i}.storage.ubicloud.com"
      end.join("\n")
    end
  
    def node_name
      index = minio_cluster.node_ipv6_sorted_by_creation.find_index{ |n| n.start_with?(vm.ephemeral_net6.to_s) } + 1
      cluster_name = minio_cluster.name
      "#{cluster_name}#{index}.storage.ubicloud.com"
    end
end
