# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:postgres_resource) do
      add_column :ephemeral, :boolean, null: false, default: false
    end
  end
end
