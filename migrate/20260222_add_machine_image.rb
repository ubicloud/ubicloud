# frozen_string_literal: true

Sequel.migration do
  up do
    create_table(:machine_image) do
      uuid :id, primary_key: true, default: Sequel.lit("gen_random_uuid()")
      String :name, null: false
      String :description, null: false, default: ""
      foreign_key :project_id, :project, type: :uuid, null: false
      foreign_key :location_id, :location, type: :uuid, null: false
      String :state, null: false
      String :s3_bucket, null: false
      String :s3_prefix, null: false
      String :s3_endpoint, null: false
      TrueClass :encrypted, null: false, default: true
      foreign_key :key_encryption_key_1_id, :storage_key_encryption_key, type: :uuid
      String :compression, null: false, default: "zstd"
      Integer :size_gib, null: false
      foreign_key :vm_id, :vm, type: :uuid, on_delete: :set_null
      String :arch, null: false, default: "x64"
      TrueClass :visible, null: false, default: false
      timestamptz :created_at, null: false, default: Sequel.lit("now()")

      unique [:project_id, :location_id, :name]
    end

    alter_table(:vm_storage_volume) do
      add_foreign_key :machine_image_id, :machine_image, type: :uuid, on_delete: :set_null
      add_column :source_fetch_total, Integer
      add_column :source_fetch_fetched, Integer
    end
  end

  down do
    alter_table(:vm_storage_volume) do
      drop_column :source_fetch_fetched
      drop_column :source_fetch_total
      drop_foreign_key :machine_image_id
    end

    drop_table(:machine_image)
  end
end
