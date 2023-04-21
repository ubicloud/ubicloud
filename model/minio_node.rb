# frozen_string_literal: true

require_relative "../model"

class MinioNode < Sequel::Model
    one_to_one :vm, key: :id
    one_to_one :strand, key: :id
    one_to_one :sshable, key: :id
    many_to_one :minio_cluster, key: :cluster_id

    include SemaphoreMethods
    semaphore :destroy, :start_node
end
