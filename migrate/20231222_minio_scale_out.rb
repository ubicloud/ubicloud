# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:minio_pool) do
      add_column :server_count, :integer, null: true
      add_column :drive_count, :integer, null: true
      add_column :storage_size_gib, :bigint, null: true
    end
  end
end
