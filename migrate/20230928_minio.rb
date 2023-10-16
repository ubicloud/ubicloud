# frozen_string_literal: true

Sequel.migration do
  change do
    create_table(:minio_cluster) do
      column :id, :uuid, primary_key: true, default: nil
      column :name, :text, null: false
      column :location, :text, collate: '"C"', null: false
      column :created_at, :timestamp, null: false, default: Sequel::CURRENT_TIMESTAMP
      column :admin_user, :text, collate: '"C"', null: false
      column :admin_password, :text, collate: '"C"', null: false
      column :target_total_storage_size_gib, :integer, null: false, default: 0
      column :target_total_pool_count, :integer, null: false, default: 0
      column :target_total_server_count, :integer, null: false, default: 0
      column :target_total_driver_count, :integer, null: false, default: 0
      column :target_vm_size, :text, collate: '"C"', null: false
      foreign_key :private_subnet_id, :private_subnet, type: :uuid, null: true
    end
    create_table(:minio_pool) do
      column :id, :uuid, primary_key: true, default: nil
      column :start_index, :integer, null: false, default: 0
      foreign_key :cluster_id, :minio_cluster, type: :uuid, null: false
    end
    create_table(:minio_server) do
      column :id, :uuid, primary_key: true, default: nil
      column :index, :integer, null: false
      foreign_key :minio_pool_id, :minio_pool, type: :uuid, null: true
      foreign_key :vm_id, :vm, type: :uuid, null: false
    end
  end
end
