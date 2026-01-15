# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:postgres_resource) do
      drop_column :version
    end
  end
end
