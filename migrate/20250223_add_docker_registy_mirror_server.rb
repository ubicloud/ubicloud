# frozen_string_literal: true

Sequel.migration do
  change do
    create_table(:docker_registry_mirror_server) do
      column :id, :uuid, primary_key: true, default: Sequel.lit("gen_random_uuid()")
      column :created_at, :timestamptz, null: false, default: Sequel::CURRENT_TIMESTAMP
      foreign_key :vm_id, :vm, type: :uuid, null: false
    end
  end
end
