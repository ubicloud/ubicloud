# frozen_string_literal: true

Sequel.migration do
  change do
    create_table(:postgres_init_script) do
      foreign_key :id, :postgres_resource, type: :uuid, primary_key: true
      column :init_script, String, null: false
    end
  end
end
