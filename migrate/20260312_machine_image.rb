# frozen_string_literal: true

Sequel.migration do
  change do
    create_table(:machine_image) do
      column :id, :uuid, primary_key: true
      column :created_at, :timestamptz, null: false, default: Sequel::CURRENT_TIMESTAMP
      column :name, :text, null: false
      column :arch, :text, collate: '"C"', null: false
      foreign_key :project_id, :project, type: :uuid, null: false
      foreign_key :location_id, :location, type: :uuid, null: false

      unique [:project_id, :location_id, :name]
    end

    create_table(:machine_image_version) do
      column :id, :uuid, primary_key: true
      foreign_key :machine_image_id, :machine_image, type: :uuid, null: false
      column :version, :text, collate: '"C"', null: false
      column :created_at, :timestamptz, null: false, default: Sequel::CURRENT_TIMESTAMP
      # enabled is false when the machine image version is still being created
      # or when it is being destroyed. Only when enabled is true, a VM can be
      # created from this machine image version.
      column :enabled, :boolean, null: false, default: false
      # actual_size_mib is the size of disk from which the machine image version
      # was created. A VM which uses this machine image version should have a disk
      # of at least this size.
      column :actual_size_mib, :integer, null: false
      # archive_size_mib is the amount of storage used in the object storage.
      # This can be smaller than the actual size because of compression. This
      # will be used for billing purposes.
      column :archive_size_mib, :integer
      foreign_key :key_encryption_key_id, :storage_key_encryption_key, type: :uuid, null: false
      column :s3_endpoint, :text, collate: '"C"', null: false
      column :s3_bucket, :text, collate: '"C"', null: false
      column :s3_prefix, :text, collate: '"C"', null: false

      unique [:machine_image_id, :version]
    end

    alter_table(:machine_image) do
      add_foreign_key :latest_version_id, :machine_image_version, type: :uuid
    end

    alter_table(:vm_storage_volume) do
      add_foreign_key :machine_image_version_id, :machine_image_version, type: :uuid

      add_constraint(
        :vm_storage_volume_single_source,
        Sequel.lit("boot_image_id IS NULL OR machine_image_version_id IS NULL")
      )
    end
  end
end
