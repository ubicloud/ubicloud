# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:postgres_resource) do
      add_column :storage_type, :text, collate: '"C"', null: false, default: "instance_storage"
      add_column :network_volume_type, :text, collate: '"C"'
      add_column :wal_drive_type, :text, collate: '"C"', null: false, default: "nvme"
      add_column :wal_drive_size_gib, :bigint
      add_constraint(:storage_type_check, Sequel.lit("storage_type IN ('instance_storage', 'network_cache')"))
      add_constraint(:network_volume_type_check, Sequel.lit("network_volume_type IS NULL OR network_volume_type IN ('gp3', 'io2')"))
      add_constraint(:wal_drive_type_check, Sequel.lit("wal_drive_type IN ('nvme', 'gp3', 'io2')"))
    end

    alter_table(:vm_storage_volume) do
      add_column :provider_volume_id, :text, collate: '"C"'
    end
  end
end
