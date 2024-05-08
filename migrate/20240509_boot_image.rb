# frozen_string_literal: true

Sequel.migration do
  change do
    create_table(:boot_image) do
      column :id, :uuid, primary_key: true
      foreign_key :vm_host_id, :vm_host, type: :uuid, null: false
      column :name, :text, collate: '"C"', null: false
      column :version, :text, collate: '"C"', null: true
      column :created_at, :timestamptz, null: false, default: Sequel.lit("now()")
      column :activated_at, :timestamptz, null: true
      unique [:vm_host_id, :name, :version]
    end

    alter_table(:vm_storage_volume) do
      add_foreign_key :boot_image_id, :boot_image, type: :uuid, null: true
    end
  end
end
