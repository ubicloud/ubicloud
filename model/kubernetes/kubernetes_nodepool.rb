#  frozen_string_literal: true

require_relative "../../model"

class KubernetesNodepool < Sequel::Model
  one_to_one :strand, key: :id, read_only: true
  many_to_one :cluster, key: :kubernetes_cluster_id, class: :KubernetesCluster, read_only: true
  many_to_many :vms, join_table: :kubernetes_node, order: [:created_at, :name], read_only: true
  one_to_many :nodes, class: :KubernetesNode, order: :created_at, read_only: true
  one_to_many :functional_nodes, class: :KubernetesNode, order: :created_at, conditions: {state: "active"}, read_only: true
  one_to_many :mesh_nodes, class: :KubernetesNode, order: :created_at, conditions: {state: ["active", "renewing_certs", "draining"]}, read_only: true

  plugin ResourceMethods
  plugin SemaphoreMethods, :destroy, :start_bootstrapping, :upgrade, :upgrade_requested, :scale_worker_count

  def path
    "#{cluster.path}/nodepool/#{ubid}"
  end

  def upgrading?
    KubernetesCluster::UPGRADE_LABELS.include?(strand.label) || upgrade_set?
  end

  def idle?
    strand.label == "wait" && semaphores.empty?
  end

  def available_upgrade_version
    cluster.version if Option.kubernetes_minor_version(version) < Option.kubernetes_minor_version(cluster.version)
  end

  def ready_for_upgrade?
    !available_upgrade_version.nil? && cluster.idle?
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
#  version                      | text                     | NOT NULL
# Indexes:
#  kubernetes_nodepool_pkey                           | PRIMARY KEY btree (id)
#  kubernetes_nodepool_kubernetes_cluster_id_name_key | UNIQUE btree (kubernetes_cluster_id, name)
# Foreign key constraints:
#  kubernetes_nodepool_kubernetes_cluster_id_fkey | (kubernetes_cluster_id) REFERENCES kubernetes_cluster(id)
# Referenced By:
#  kubernetes_node | kubernetes_node_kubernetes_nodepool_id_fkey | (kubernetes_nodepool_id) REFERENCES kubernetes_nodepool(id)
