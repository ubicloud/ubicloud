#  frozen_string_literal: true

require_relative "../../model"

class KubernetesNodepool < Sequel::Model
  one_to_one :strand, key: :id
  many_to_one :cluster, key: :kubernetes_cluster_id, class: :KubernetesCluster
  many_to_many :vms, join_table: :kubernetes_node, right_key: :vm_id, class: :Vm, order: :created_at
  one_to_many :nodes, class: :KubernetesNode, order: :created_at
  one_to_many :functional_nodes, class: :KubernetesNode, order: :created_at, conditions: {state: "active"}

  plugin ResourceMethods
  plugin SemaphoreMethods, :destroy, :start_bootstrapping, :upgrade, :scale_worker_count

  def path
    "#{cluster.path}/nodepool/#{ubid}"
  end
end

# Table: kubernetes_nodepool
# Columns:
#  id                           | uuid                     | PRIMARY KEY
#  name                         | text                     | NOT NULL
#  node_count                   | integer                  | NOT NULL
#  created_at                   | timestamp with time zone | NOT NULL DEFAULT CURRENT_TIMESTAMP
#  kubernetes_cluster_id        | uuid                     | NOT NULL
#  target_node_size             | text                     | NOT NULL
#  target_node_storage_size_gib | bigint                   |
# Indexes:
#  kubernetes_nodepool_pkey | PRIMARY KEY btree (id)
# Foreign key constraints:
#  kubernetes_nodepool_kubernetes_cluster_id_fkey | (kubernetes_cluster_id) REFERENCES kubernetes_cluster(id)
# Referenced By:
#  kubernetes_node | kubernetes_node_kubernetes_nodepool_id_fkey | (kubernetes_nodepool_id) REFERENCES kubernetes_nodepool(id)
