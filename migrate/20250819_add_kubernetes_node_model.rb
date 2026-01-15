# frozen_string_literal: true

Sequel.migration do
  change do
    create_table(:kubernetes_node) do
      column :id, :uuid, primary_key: true
      column :created_at, :timestamptz, null: false, default: Sequel::CURRENT_TIMESTAMP
      foreign_key :vm_id, :vm, type: :uuid, null: false
      foreign_key :kubernetes_cluster_id, :kubernetes_cluster, type: :uuid, null: false
      foreign_key :kubernetes_nodepool_id, :kubernetes_nodepool, type: :uuid, null: true
    end
  end
end
