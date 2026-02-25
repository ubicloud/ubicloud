# frozen_string_literal: true

Sequel.migration do
  up do
    create_table(:machine_image_version) do
      uuid :id, primary_key: true, default: Sequel.lit("gen_random_uuid()")
      foreign_key :machine_image_id, :machine_image, type: :uuid, null: false
      Integer :version, null: false
      String :state, null: false
      Integer :size_gib, null: false
      String :arch, null: false, default: "x64"
      foreign_key :key_encryption_key_1_id, :storage_key_encryption_key, type: :uuid
      String :s3_bucket, null: false
      String :s3_prefix, null: false
      String :s3_endpoint, null: false
      foreign_key :vm_id, :vm, type: :uuid, on_delete: :set_null
      timestamptz :activated_at
      timestamptz :created_at, null: false, default: Sequel.lit("now()")

      unique [:machine_image_id, :version]
    end

    # Migrate existing data: create a machine_image_version row for each existing machine_image row
    run <<~SQL
      INSERT INTO machine_image_version (id, machine_image_id, version, state, size_gib, arch,
        key_encryption_key_1_id, s3_bucket, s3_prefix, s3_endpoint, vm_id, activated_at, created_at)
      SELECT gen_random_uuid(), id,
        COALESCE(REPLACE(version, 'v', '')::integer, 1),
        state, size_gib, arch,
        key_encryption_key_1_id, s3_bucket, s3_prefix, s3_endpoint, vm_id,
        CASE WHEN active THEN created_at END,
        created_at
      FROM machine_image;
    SQL

    # Update vm_storage_volume to point to machine_image_version instead of machine_image
    alter_table(:vm_storage_volume) do
      add_foreign_key :machine_image_version_id, :machine_image_version, type: :uuid, on_delete: :set_null
    end

    # Migrate FK references: for each vm_storage_volume with machine_image_id, find the matching version
    run <<~SQL
      UPDATE vm_storage_volume vsv
      SET machine_image_version_id = (
        SELECT miv.id FROM machine_image_version miv
        WHERE miv.machine_image_id = vsv.machine_image_id
        AND miv.activated_at IS NOT NULL
        ORDER BY miv.activated_at DESC
        LIMIT 1
      )
      WHERE vsv.machine_image_id IS NOT NULL;
    SQL

    alter_table(:vm_storage_volume) do
      drop_foreign_key :machine_image_id
    end

    # Remove version-specific columns from machine_image
    alter_table(:machine_image) do
      drop_column :version
      drop_column :state
      drop_column :size_gib
      drop_column :arch
      drop_column :key_encryption_key_1_id
      drop_column :s3_bucket
      drop_column :s3_prefix
      drop_column :s3_endpoint
      drop_column :vm_id
      drop_column :active
      drop_column :encrypted
      drop_column :compression
      drop_column :decommissioned_at
    end

    # Add unique constraint on machine_image (project_id, location_id, name) - no longer per-version
    alter_table(:machine_image) do
      add_unique_constraint [:project_id, :location_id, :name]
    end
  end

  down do
    # Add columns back to machine_image
    alter_table(:machine_image) do
      drop_constraint :machine_image_project_id_location_id_name_key
      add_column :version, String, null: false, default: "v1"
      add_column :state, String, null: false, default: "available"
      add_column :size_gib, Integer, null: false, default: 0
      add_column :arch, String, null: false, default: "x64"
      add_foreign_key :key_encryption_key_1_id, :storage_key_encryption_key, type: :uuid
      add_column :s3_bucket, String, null: false, default: ""
      add_column :s3_prefix, String, null: false, default: ""
      add_column :s3_endpoint, String, null: false, default: ""
      add_foreign_key :vm_id, :vm, type: :uuid, on_delete: :set_null
      add_column :active, TrueClass, null: false, default: true
      add_column :encrypted, TrueClass, null: false, default: true
      add_column :compression, String, null: false, default: "zstd"
      add_column :decommissioned_at, :timestamptz
    end

    alter_table(:vm_storage_volume) do
      add_foreign_key :machine_image_id, :machine_image, type: :uuid, on_delete: :set_null
    end

    alter_table(:vm_storage_volume) do
      drop_foreign_key :machine_image_version_id
    end

    drop_table(:machine_image_version)
  end
end
