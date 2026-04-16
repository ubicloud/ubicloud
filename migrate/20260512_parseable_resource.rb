# frozen_string_literal: true

Sequel.migration do
  change do
    create_table(:parseable_resource) do
      # UBID.to_base32_n("p1") => 705
      column :id, :uuid, primary_key: true, default: Sequel.function(:gen_random_ubid_uuid, 705)
      column :name, :text, null: false
      column :created_at, :timestamptz, null: false, default: Sequel::CURRENT_TIMESTAMP
      column :admin_user, :text, collate: '"C"', null: false
      column :admin_password, :text, collate: '"C"', null: false
      column :blob_storage_access_key, :text, collate: '"C"', null: false
      column :blob_storage_secret_key, :text, collate: '"C"', null: false
      column :target_vm_size, :text, collate: '"C"', null: false
      column :target_storage_size_gib, :bigint, null: false
      column :root_cert_1, :text, collate: '"C"'
      column :root_cert_key_1, :text, collate: '"C"'
      column :root_cert_2, :text, collate: '"C"'
      column :root_cert_key_2, :text, collate: '"C"'
      column :certificate_last_checked_at, :timestamptz, null: false, default: Sequel::CURRENT_TIMESTAMP
      foreign_key :project_id, :project, type: :uuid, null: false
      foreign_key :location_id, :location, type: :uuid, null: false
      foreign_key :private_subnet_id, :private_subnet, type: :uuid, null: true
    end

    create_table(:parseable_server) do
      # UBID.to_base32_n("pe") => 718
      column :id, :uuid, primary_key: true, default: Sequel.function(:gen_random_ubid_uuid, 718)
      column :created_at, :timestamptz, null: false, default: Sequel::CURRENT_TIMESTAMP
      column :cert, :text, collate: '"C"'
      column :cert_key, :text, collate: '"C"'
      column :certificate_last_checked_at, :timestamptz, null: false, default: Sequel::CURRENT_TIMESTAMP
      foreign_key :parseable_resource_id, :parseable_resource, type: :uuid, null: false
      foreign_key :vm_id, :vm, type: :uuid, null: false
    end

    alter_table(:postgres_resource) do
      add_column :parseable_password, :text, collate: '"C"'
    end
  end
end
