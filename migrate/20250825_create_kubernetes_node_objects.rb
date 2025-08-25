# frozen_string_literal: true

Sequel.migration do
  up do
    DB[:kubernetes_node].import(
      [:id, :vm_id, :kubernetes_cluster_id],
      DB[:kubernetes_cluster]
        .join(:kubernetes_clusters_cp_vms, kubernetes_cluster_id: :id)
        .join(:vm, id: :cp_vm_id)
        .select(
          Sequel.function(:gen_timestamp_ubid_uuid, 621).as(:id),
          Sequel[:vm][:id].as(:vm_id),
          Sequel[:kubernetes_cluster][:id].as(:kubernetes_cluster_id)
        )
    )

    DB[:kubernetes_node].import(
      [:id, :vm_id, :kubernetes_cluster_id, :kubernetes_nodepool_id],
      DB[:kubernetes_cluster]
        .join(:kubernetes_nodepool, kubernetes_cluster_id: :id)
        .join(:kubernetes_nodepools_vms, kubernetes_nodepool_id: :id)
        .join(:vm, id: :vm_id)
        .select(
          Sequel.function(:gen_timestamp_ubid_uuid, 621).as(:id),
          Sequel[:vm][:id].as(:vm_id),
          Sequel[:kubernetes_cluster][:id].as(:kubernetes_cluster_id),
          Sequel[:kubernetes_nodepool][:id].as(:kubernetes_nodepool_id)
        )
    )

    DB[:strand].import(
      [:id, :prog, :label],
      DB[:kubernetes_node]
        .select(
          Sequel[:kubernetes_node][:id],
          "Kubernetes::KubernetesNodeNexus",
          "wait"
        )
    )
  end
end
