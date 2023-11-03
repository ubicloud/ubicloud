# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:postgres_resource) do
      add_foreign_key :parent_id, :postgres_resource, type: :uuid, null: true
      add_column :restore_target, :timestamptz, null: true
    end
  end
end
