#  frozen_string_literal: true

require_relative "../../model"

class KubernetesNode < Sequel::Model
  one_to_one :strand, key: :id
  many_to_one :vm
  many_to_one :kubernetes_cluster
  many_to_one :kubernetes_nodepool

  plugin ResourceMethods
end

# Table: kubernetes_node
# Columns:
#  id                     | uuid                     | PRIMARY KEY
#  created_at             | timestamp with time zone | NOT NULL DEFAULT CURRENT_TIMESTAMP
#  vm_id                  | uuid                     | NOT NULL
#  kubernetes_cluster_id  | uuid                     | NOT NULL
#  kubernetes_nodepool_id | uuid                     |
# Indexes:
#  kubernetes_node_pkey | PRIMARY KEY btree (id)
# Foreign key constraints:
#  kubernetes_node_kubernetes_cluster_id_fkey  | (kubernetes_cluster_id) REFERENCES kubernetes_cluster(id)
#  kubernetes_node_kubernetes_nodepool_id_fkey | (kubernetes_nodepool_id) REFERENCES kubernetes_nodepool(id)
#  kubernetes_node_vm_id_fkey                  | (vm_id) REFERENCES vm(id)
