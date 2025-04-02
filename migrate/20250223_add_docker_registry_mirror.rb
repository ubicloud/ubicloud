# frozen_string_literal: true

Sequel.migration do
  change do
    create_table(:docker_registry_mirror) do
      column :id, :uuid, primary_key: true
      column :created_at, :timestamptz, null: false, default: Sequel::CURRENT_TIMESTAMP
      column :last_certificate_reset_at, :timestamptz, null: false, default: Sequel::CURRENT_TIMESTAMP
      foreign_key :vm_id, :vm, type: :uuid, null: false
    end
  end
end
