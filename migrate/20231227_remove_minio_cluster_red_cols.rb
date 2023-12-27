# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:minio_cluster) do
      drop_column :target_total_storage_size_gib
      drop_column :target_total_pool_count
      drop_column :target_total_server_count
      drop_column :target_total_drive_count
      drop_column :target_vm_size
    end
  end
end
