# frozen_string_literal: true

Sequel.migration do
  change do
    create_table(:machine_image) do
      column :id, :uuid, primary_key: true, default: Sequel.lit("gen_random_ubid_uuid(641)") # m1 ubid type
      column :created_at, :timestamptz, null: false, default: Sequel::CURRENT_TIMESTAMP
      column :name, :text, null: false
      column :arch, :text, collate: '"C"', null: false
      foreign_key :project_id, :project, type: :uuid, null: false
      foreign_key :location_id, :location, type: :uuid, null: false

      unique [:project_id, :location_id, :name]
      constraint(:arch_is_valid, "arch IN ('x64', 'arm64')")
    end

    create_table(:machine_image_store) do
      column :id, :uuid, primary_key: true, default: Sequel.lit("gen_random_ubid_uuid(640)") # m0 ubid type

      # For each location, the row with project_id ==
      # Config.machine_images_service_project_id defines the default image
      # store. Projects can override this by having their own (project_id,
      # location_id) entry.
      foreign_key :project_id, :project, type: :uuid, null: false
      foreign_key :location_id, :location, type: :uuid, null: false

      column :provider, :text, collate: '"C"', null: false
      column :region, :text, collate: '"C"', null: false
      column :endpoint, :text, collate: '"C"', null: false
      column :bucket, :text, collate: '"C"', null: false
      column :access_key, :text, collate: '"C"', null: false
      column :secret_key, :text, collate: '"C"', null: false

      unique [:project_id, :location_id]
    end

    create_table(:machine_image_version) do
      column :id, :uuid, primary_key: true, default: Sequel.lit("gen_random_ubid_uuid(667)") # mv ubid type
      foreign_key :machine_image_id, :machine_image, type: :uuid, null: false
      column :version, :text, collate: '"C"', null: false
      column :created_at, :timestamptz, null: false, default: Sequel::CURRENT_TIMESTAMP

      # actual_size_mib is the size of disk from which the machine image version
      # was created. A VM which uses this machine image version should have a
      # disk of at least this size. This can be null when the machine image
      # version creation is still in progress from a URL source and the size has
      # not been determined yet.
      column :actual_size_mib, :integer

      unique [:machine_image_id, :version]
    end

    create_table(:machine_image_version_metal) do
      foreign_key :id, :machine_image_version, type: :uuid, primary_key: true

      # enabled is false when the machine image version is still being created
      # or when it is being destroyed. Only when enabled is true, a VM can be
      # created from this machine image version.
      column :enabled, :boolean, null: false, default: false

      # archive_size_mib is the amount of storage used in the object storage.
      # This can be smaller than the actual size because of compression. This
      # will be used for billing purposes.
      column :archive_size_mib, :integer

      # The data in the archive is encrypted with a randomly generated data
      # encryption key (DEK). The DEK is encrypted using archive_kek and is
      # stored in `metadata.json` at the object storage.
      foreign_key :archive_kek_id, :storage_key_encryption_key, type: :uuid, null: false

      foreign_key :store_id, :machine_image_store, type: :uuid, null: false
      column :store_prefix, :text, collate: '"C"', null: false

      constraint(:size_set_if_enabled, "NOT enabled OR archive_size_mib IS NOT NULL")
    end

    alter_table(:machine_image) do
      add_foreign_key :latest_version_id, :machine_image_version, type: :uuid
    end

    alter_table(:vm_storage_volume) do
      add_foreign_key :machine_image_version_id, :machine_image_version, type: :uuid

      add_constraint(
        :vm_storage_volume_single_source,
        "boot_image_id IS NULL OR machine_image_version_id IS NULL",
      )
    end
  end
end
