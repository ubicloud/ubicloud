# frozen_string_literal: true

Sequel.migration do
  change do
    # Keep provider identity and configuration separate from the VM attachment.
    create_table(:network_volume) do
      column :id, :uuid, primary_key: true, default: Sequel.lit("gen_random_ubid_uuid(699)") # nv ubid type
      column :created_at, :timestamptz, null: false, default: Sequel::CURRENT_TIMESTAMP

      foreign_key :location_id, :location, type: :uuid, null: false

      # Persist the provider identifier for retries and cleanup.
      column :provider_id, :text, collate: '"C"'

      column :size_gib, :bigint, null: false
      constraint(:network_volume_size_positive, Sequel.lit("size_gib > 0"))
    end

    # Provider configuration shares the network volume's identity.
    create_table(:aws_volume) do
      foreign_key :id, :network_volume, type: :uuid, primary_key: true, on_delete: :cascade
      column :volume_type, :text, collate: '"C"', null: false
      column :provisioned_iops, :integer
      column :provisioned_throughput_mibps, :integer

      constraint(:aws_volume_type_check, Sequel.lit("volume_type IN ('gp3', 'io2')"))
      constraint(:aws_volume_iops_positive, Sequel.lit("provisioned_iops IS NULL OR provisioned_iops > 0"))
      constraint(:aws_volume_throughput_positive, Sequel.lit("provisioned_throughput_mibps IS NULL OR provisioned_throughput_mibps > 0"))
    end

    create_table(:gcp_volume) do
      foreign_key :id, :network_volume, type: :uuid, primary_key: true, on_delete: :cascade
      column :volume_type, :text, collate: '"C"', null: false
      column :provisioned_iops, :integer
      column :provisioned_throughput_mibps, :integer

      constraint(:gcp_volume_type_check, Sequel.lit("volume_type IN ('hyperdisk-balanced')"))
      constraint(:gcp_volume_iops_positive, Sequel.lit("provisioned_iops IS NULL OR provisioned_iops > 0"))
      constraint(:gcp_volume_throughput_positive, Sequel.lit("provisioned_throughput_mibps IS NULL OR provisioned_throughput_mibps > 0"))
    end

    # ext4 volumes attach to at most one VM.
    alter_table(:vm_storage_volume) do
      add_foreign_key :network_volume_id, :network_volume, type: :uuid, unique: true
    end

    # Store the PostgreSQL data medium in one column.
    alter_table(:postgres_resource) do
      add_column :storage_type, :text, collate: '"C"', null: false, default: "local-nvme"
      add_constraint(:storage_type_check, Sequel.lit("storage_type IN ('local-nvme', 'gp3', 'io2', 'hyperdisk-balanced')"))
    end
  end
end
