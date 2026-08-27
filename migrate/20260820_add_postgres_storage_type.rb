# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:postgres_resource) do
      add_column :storage_type, :text, collate: '"C"', null: false, default: "instance_storage"
      add_column :network_volume_type, :text, collate: '"C"'
      add_column :wal_drive_type, :text, collate: '"C"', null: false, default: "nvme"
      add_column :wal_drive_size_gib, :bigint
      add_constraint(:storage_type_check, Sequel.lit("storage_type IN ('instance_storage', 'network_cache')"))
      add_constraint(:network_volume_type_check, Sequel.lit("network_volume_type IS NULL OR network_volume_type IN ('gp3', 'io2', 'hyperdisk-balanced')"))
      add_constraint(:wal_drive_type_check, Sequel.lit("wal_drive_type IN ('nvme', 'gp3', 'io2', 'hyperdisk-balanced')"))
    end

    alter_table(:vm_storage_volume) do
      add_column :provider_volume_id, :text, collate: '"C"'
      add_column :volume_type, :text, collate: '"C"'
      add_column :provisioned_iops, :integer
      add_column :provisioned_throughput_mibps, :integer

      add_constraint(:volume_type_check, Sequel.lit("volume_type IS NULL OR volume_type IN ('gp3', 'io2', 'hyperdisk-balanced')"))
      add_constraint(:provisioned_config_needs_volume_type, Sequel.lit("volume_type IS NOT NULL OR (provisioned_iops IS NULL AND provisioned_throughput_mibps IS NULL)"))
      add_constraint(:provisioned_iops_positive, Sequel.lit("provisioned_iops IS NULL OR provisioned_iops > 0"))
      add_constraint(:provisioned_throughput_mibps_positive, Sequel.lit("provisioned_throughput_mibps IS NULL OR provisioned_throughput_mibps > 0"))
    end
  end
end
