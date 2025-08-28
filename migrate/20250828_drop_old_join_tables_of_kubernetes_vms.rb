# frozen_string_literal: true

Sequel.migration do
  revert do
    create_table(:kubernetes_clusters_cp_vms) do
      foreign_key :kubernetes_cluster_id, :kubernetes_cluster, type: :uuid, null: false
      foreign_key :cp_vm_id, :vm, type: :uuid, null: false

      primary_key [:kubernetes_cluster_id, :cp_vm_id]
      index [:cp_vm_id, :kubernetes_cluster_id]
    end

    create_table(:kubernetes_nodepools_vms) do
      foreign_key :kubernetes_nodepool_id, :kubernetes_nodepool, type: :uuid, null: false
      foreign_key :vm_id, :vm, type: :uuid, null: false

      primary_key [:kubernetes_nodepool_id, :vm_id]
      index [:vm_id, :kubernetes_nodepool_id]
    end
  end
end
