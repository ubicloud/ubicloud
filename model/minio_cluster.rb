# frozen_string_literal: true

require_relative "../model"

class MinioCluster < Sequel::Model
  one_to_many :minio_node, key: :cluster_id
end
