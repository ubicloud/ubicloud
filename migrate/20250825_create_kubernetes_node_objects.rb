# frozen_string_literal: true

Sequel.migration do
  up do
    DB[:kubernetes_node].insert_ignore.insert(
      [:id, :vm_id, :kubernetes_cluster_id],
      DB[:kubernetes_clusters_cp_vms].select(
        Sequel.function(:gen_random_ubid_uuid, 621).as(:id),
        :cp_vm_id,
        :kubernetes_cluster_id
      )
    )

    DB[:kubernetes_node].insert_ignore.insert(
      [:id, :vm_id, :kubernetes_cluster_id, :kubernetes_nodepool_id],
      DB[:kubernetes_nodepools_vms]
        .join(:kubernetes_nodepool, id: :kubernetes_nodepool_id)
        .select(
          Sequel.function(:gen_random_ubid_uuid, 621).as(:id),
          :vm_id,
          :kubernetes_cluster_id,
          :kubernetes_nodepool_id
        )
    )

    DB[:strand].insert_ignore.insert(
      [:id, :prog, :label],
      DB[:kubernetes_node]
        .select(
          :id,
          "Kubernetes::KubernetesNodeNexus",
          "wait"
        )
    )
  end
end
