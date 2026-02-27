# frozen_string_literal: true

Sequel.migration do
  up do
    create_table(:machine_image) do
      uuid :id, primary_key: true, default: Sequel.lit("gen_random_uuid()")
      String :name, null: false
      String :description, null: false, default: ""
      foreign_key :project_id, :project, type: :uuid, null: false
      foreign_key :location_id, :location, type: :uuid, null: false
      String :arch, null: false, default: "x64"
      TrueClass :deleting, null: false, default: false
      timestamptz :created_at, null: false, default: Sequel.lit("now()")

      unique [:project_id, :location_id, :name]
    end

    create_table(:machine_image_version) do
      uuid :id, primary_key: true, default: Sequel.lit("gen_random_uuid()")
      foreign_key :machine_image_id, :machine_image, type: :uuid, null: false
      Integer :version, null: false
      String :state, null: false
      Integer :size_gib, null: false
      Integer :archive_size_mib
      foreign_key :key_encryption_key_1_id, :storage_key_encryption_key, type: :uuid
      String :s3_bucket, null: false
      String :s3_prefix, null: false
      String :s3_endpoint, null: false
      foreign_key :vm_id, :vm, type: :uuid, on_delete: :set_null
      timestamptz :activated_at
      timestamptz :created_at, null: false, default: Sequel.lit("now()")

      unique [:machine_image_id, :version]
    end

    alter_table(:vm_storage_volume) do
      add_foreign_key :machine_image_version_id, :machine_image_version, type: :uuid, on_delete: :set_null
      add_column :source_fetch_state, String
    end
  end

  down do
    alter_table(:vm_storage_volume) do
      drop_column :source_fetch_state
      drop_foreign_key :machine_image_version_id
    end

    drop_table(:machine_image_version)
    drop_table(:machine_image)
  end
end
