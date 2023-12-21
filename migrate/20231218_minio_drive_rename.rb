# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:minio_cluster) do
      rename_column :target_total_driver_count, :target_total_drive_count
    end
  end
end
