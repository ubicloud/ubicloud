# frozen_string_literal: true

Sequel.migration do
  change do
    create_table(:kubernetes_cluster) do
      column :id, :uuid, primary_key: true
      column :name, :text, null: false
      column :cp_node_count, :integer, null: false
      column :version, :text, null: false
      column :location, :text, collate: '"C"', null: false
      column :created_at, Time, null: false, default: Sequel::CURRENT_TIMESTAMP

      foreign_key :project_id, :project, type: :uuid, null: false
      foreign_key :private_subnet_id, :private_subnet, type: :uuid, null: false
      foreign_key :api_server_lb_id, :load_balancer, type: :uuid, null: true

      index [:project_id, :location, :name], name: :kubernetes_cluster_project_id_location_name_uidx, unique: true
    end

    create_table(:kubernetes_clusters_cp_vms) do
      foreign_key :kubernetes_cluster_id, :kubernetes_cluster, type: :uuid, null: false
      foreign_key :cp_vm_id, :vm, type: :uuid, null: false

      primary_key [:kubernetes_cluster_id, :cp_vm_id]
      index [:cp_vm_id, :kubernetes_cluster_id]
    end

    create_table(:kubernetes_nodepool) do
      column :id, :uuid, primary_key: true
      column :name, :text, null: false
      column :node_count, :integer, null: false
      column :created_at, Time, null: false, default: Sequel::CURRENT_TIMESTAMP

      foreign_key :kubernetes_cluster_id, :kubernetes_cluster, type: :uuid, null: false
    end

    create_table(:kubernetes_nodepools_vms) do
      foreign_key :kubernetes_nodepool_id, :kubernetes_nodepool, type: :uuid, null: false
      foreign_key :vm_id, :vm, type: :uuid, null: false

      primary_key [:kubernetes_nodepool_id, :vm_id]
      index [:vm_id, :kubernetes_nodepool_id]
    end
  end
end
