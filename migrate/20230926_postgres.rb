# frozen_string_literal: true

Sequel.migration do
  change do
    create_table(:postgres_server) do
      column :id, :uuid, primary_key: true, default: nil
      column :created_at, :timestamptz, null: false, default: Sequel.lit("now()")
      column :updated_at, :timestamptz, null: false, default: Sequel.lit("now()")
      column :project_id, :project, type: :uuid, null: false
      column :location, :text, collate: '"C"', null: false
      column :server_name, :text, collate: '"C"', null: false, unique: true
      column :target_vm_size, :text, collate: '"C"', null: false
      column :target_storage_size_gib, :bigint, null: false
      column :superuser_password, :text, collate: '"C"', null: false
      column :vm_id, :vm, type: :uuid
    end
  end
end
