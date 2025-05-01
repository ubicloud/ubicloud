# frozen_string_literal: true

Sequel.migration do
  change do
    create_table(:victoria_metrics_resource) do
      column :id, :uuid, primary_key: true
      column :name, :text, null: false
      column :created_at, :timestamptz, null: false, default: Sequel.lit("now()")
      column :admin_user, :text, collate: '"C"', null: false
      column :admin_password, :text, collate: '"C"', null: false
      column :target_vm_size, :text, collate: '"C"', null: false
      column :target_storage_size_gib, :bigint, null: false
      column :root_cert_1, :text, collate: '"C"'
      column :root_cert_key_1, :text, collate: '"C"'
      column :root_cert_2, :text, collate: '"C"'
      column :root_cert_key_2, :text, collate: '"C"'
      column :certificate_last_checked_at, :timestamptz, null: false, default: Sequel.lit("now()")
      foreign_key :project_id, :project, type: :uuid, null: false
      foreign_key :location_id, :location, type: :uuid, null: false
      foreign_key :private_subnet_id, :private_subnet, type: :uuid, null: true
    end
    create_table(:victoria_metrics_server) do
      column :id, :uuid, primary_key: true
      column :created_at, :timestamptz, null: false, default: Sequel.lit("now()")
      column :cert, :text, collate: '"C"'
      column :cert_key, :text, collate: '"C"'
      column :certificate_last_checked_at, :timestamptz, null: false, default: Sequel.lit("now()")
      foreign_key :victoria_metrics_resource_id, :victoria_metrics_resource, type: :uuid, null: false
      foreign_key :vm_id, :vm, type: :uuid, null: false
    end
  end
end
