#  frozen_string_literal: true

require_relative "../../model"

class KubernetesNode < Sequel::Model
  one_to_one :strand, key: :id
  many_to_one :vm
  many_to_one :kubernetes_cluster
  many_to_one :kubernetes_nodepool

  plugin ResourceMethods
  plugin SemaphoreMethods, :destroy

  def sshable
    vm.sshable
  end

  def billing_record
    if kubernetes_nodepool
      worker_billing_records
    else
      control_plane_billing_record
    end
  end

  def worker_billing_records
    [
      {type: "KubernetesWorkerVCpu", family: vm.family, amount: vm.vcpus},
      {type: "KubernetesWorkerStorage", family: "standard", amount: vm.storage_size_gib}
    ]
  end

  def control_plane_billing_record
    [
      {type: "KubernetesControlPlaneVCpu", family: vm.family, amount: vm.vcpus}
    ]
  end

  def name
    vm.name
  end
end

# Table: kubernetes_node
# Columns:
#  id                     | uuid                     | PRIMARY KEY
#  created_at             | timestamp with time zone | NOT NULL DEFAULT CURRENT_TIMESTAMP
#  vm_id                  | uuid                     | NOT NULL
#  kubernetes_cluster_id  | uuid                     | NOT NULL
#  kubernetes_nodepool_id | uuid                     |
#  state                  | text                     | NOT NULL DEFAULT 'active'::text
# Indexes:
#  kubernetes_node_pkey | PRIMARY KEY btree (id)
# Foreign key constraints:
#  kubernetes_node_kubernetes_cluster_id_fkey  | (kubernetes_cluster_id) REFERENCES kubernetes_cluster(id)
#  kubernetes_node_kubernetes_nodepool_id_fkey | (kubernetes_nodepool_id) REFERENCES kubernetes_nodepool(id)
#  kubernetes_node_vm_id_fkey                  | (vm_id) REFERENCES vm(id)
