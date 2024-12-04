# frozen_string_literal: true

Sequel.migration do
  change do
    create_table(:kubernetes_cluster) do
      column :id, :uuid, primary_key: true, default: Sequel.lit("gen_random_uuid()")
      column :name, :text, null: false
      column :replica, :integer, null: false
      column :kubernetes_version, :text, null: false
      column :subnet, :text, null: false
      column :location, :text, collate: '"C"', null: false
      column :created_at, :timestamp, null: false, default: Sequel::CURRENT_TIMESTAMP

      check { (replica =~ [1, 3]) }
    end

    create_table(:kubernetes_nodepool) do
      column :id, :uuid, primary_key: true, default: Sequel.lit("gen_random_uuid()")
      column :name, :text, null: false
      column :replica, :integer, null: false
      column :kubernetes_version, :text, null: false
      column :location, :text, collate: '"C"', null: false
      column :created_at, :timestamp, null: false, default: Sequel::CURRENT_TIMESTAMP
      column :kubernetes_cluster_id, :uuid, null: false

      foreign_key [:kubernetes_cluster_id], :kubernetes_cluster, key: :id, on_delete: :cascade
    end
  end
end
