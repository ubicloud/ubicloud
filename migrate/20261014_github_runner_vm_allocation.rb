# frozen_string_literal: true

Sequel.migration do
  change do
    create_table(:github_runner_vm_allocation) do
      foreign_key :vm_id, :vm, type: :uuid, primary_key: true
      column :label, :text, null: false, collate: '"C"'
      foreign_key :location_id, :location, type: :uuid, null: false
      foreign_key :vm_host_id, :vm_host, type: :uuid, null: false
      column :created_at, :timestamptz, null: false, default: Sequel::CURRENT_TIMESTAMP
      column :generation, Integer, null: false, default: 1
      index [:label, :location_id, :created_at]
    end
  end
end
