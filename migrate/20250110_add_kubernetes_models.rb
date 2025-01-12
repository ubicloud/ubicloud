# frozen_string_literal: true

Sequel.migration do
  change do
    create_table(:kubernetes_cluster) do
      column :id, :uuid, primary_key: true
      column :name, :text, null: false
      column :cp_node_count, :integer, null: false
      column :kubernetes_version, :text, null: false
      column :location, :text, collate: '"C"', null: false
      column :created_at, :timestamp, null: false, default: Sequel::CURRENT_TIMESTAMP

      check { (cp_node_count =~ [1, 3]) }
      foreign_key :project_id, :project, type: :uuid, null: false
      foreign_key :private_subnet_id, :private_subnet, type: :uuid, null: false
      foreign_key :api_server_lb_id, :load_balancer, type: :uuid, null: true
    end

    create_table(:kubernetes_clusters_vms) do
      foreign_key :kubernetes_cluster_id, :kubernetes_cluster, type: :uuid, null: false
      foreign_key :vm_id, :vm, type: :uuid, null: false

      index [:kubernetes_cluster_id, :vm_id], unique: true
    end

    create_table(:kubernetes_nodepool) do
      column :id, :uuid, primary_key: true
      column :name, :text, null: false
      column :node_count, :integer, null: false
      column :created_at, :timestamp, null: false, default: Sequel::CURRENT_TIMESTAMP

      foreign_key :kubernetes_cluster_id, :kubernetes_cluster, type: :uuid, null: false
    end

    create_table(:kubernetes_nodepools_vms) do
      foreign_key :kubernetes_nodepool_id, :kubernetes_nodepool, type: :uuid, null: false
      foreign_key :vm_id, :vm, type: :uuid, null: false

      index [:kubernetes_nodepool_id, :vm_id], unique: true
    end
  end
end
