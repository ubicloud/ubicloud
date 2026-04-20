# frozen_string_literal: true

Sequel.migration do
  change do
    create_table(:vm_gcp_resource) do
      foreign_key :id, :vm, type: :uuid, primary_key: true, on_delete: :cascade
      foreign_key :location_az_id, :location_az, type: :uuid, null: false
      column :created_at, :timestamptz, null: false, default: Sequel::CURRENT_TIMESTAMP
      index :location_az_id
    end
  end
end
