# frozen_string_literal: true

Sequel.migration do
  change do
    create_table(:minio_cluster) do
      column :id, :uuid, primary_key: true, default: Sequel.function(:gen_random_uuid)
      column :name, :text, null: false, unique: true, default: Sequel.function(:gen_random_uuid)
      column :created_at, :timestamp, null: false, default: Sequel::CURRENT_TIMESTAMP
      column :admin_user, :text, null: false, default: Sequel.function(:gen_random_uuid)
      column :admin_password, :text, null: false, default: Sequel.function(:gen_random_uuid)
      column :pool_count, :integer, null: false, default: 0
      column :capacity, :integer, null: false, default: 0
    end
    create_table(:minio_pool) do
      column :id, :uuid, primary_key: true, default: Sequel.function(:gen_random_uuid)
      column :created_at, :timestamp, null: false, default: Sequel::CURRENT_TIMESTAMP
      column :node_count, :integer, null: false, default: 0
      column :capacity, :integer, null: false, default: 0
      column :start_index, :integer, null: false, default: 0
      foreign_key :cluster_id, :minio_cluster, type: :uuid, null: false
    end
    create_table(:minio_node) do
      column :id, :uuid, primary_key: true, default: Sequel.function(:gen_random_uuid)
      column :capacity, :integer, null: false, default: 0
      column :created_at, :timestamp, null: false, default: Sequel::CURRENT_TIMESTAMP
      foreign_key :pool_id, :minio_pool, type: :uuid, null: false
    end
  end
end
