# frozen_string_literal: true

Sequel.migration do
  up do
    create_table(:postgres_server) do
      column :id, :uuid, primary_key: true, default: nil
      column :created_at, :timestamptz, null: false, default: Sequel.lit("now()")
      column :updated_at, :timestamptz, null: false, default: Sequel.lit("now()")
      column :resource_id, :postgres_resource, type: :uuid, null: false
      foreign_key :vm_id, :vm, type: :uuid
    end

    alter_table(:postgres_resource) do
      drop_column :vm_id
    end
  end

  down do
    drop_table :postgres_server

    alter_table(:postgres_resource) do
      add_column :vm_id, :uuid
    end
  end
end
