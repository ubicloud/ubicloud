# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:postgres_resource) do
      rename_column :server_name, :name
    end
  end
end
