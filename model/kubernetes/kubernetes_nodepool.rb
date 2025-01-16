#  frozen_string_literal: true

require_relative "../../model"

class KubernetesNodepool < Sequel::Model
  one_to_one :strand, key: :id
  many_to_one :kubernetes_cluster
  many_to_many :vms, order: :created_at

  include ResourceMethods
  include SemaphoreMethods

  semaphore :destroy
end

# Table: kubernetes_nodepool
# Columns:
#  id                    | uuid                        | PRIMARY KEY
#  name                  | text                        | NOT NULL
#  node_count            | integer                     | NOT NULL
#  created_at            | timestamp without time zone | NOT NULL DEFAULT CURRENT_TIMESTAMP
#  kubernetes_cluster_id | uuid                        | NOT NULL
# Indexes:
#  kubernetes_nodepool_pkey | PRIMARY KEY btree (id)
# Foreign key constraints:
#  kubernetes_nodepool_kubernetes_cluster_id_fkey | (kubernetes_cluster_id) REFERENCES kubernetes_cluster(id)
# Referenced By:
#  kubernetes_nodepools_vms | kubernetes_nodepools_vms_kubernetes_nodepool_id_fkey | (kubernetes_nodepool_id) REFERENCES kubernetes_nodepool(id)
