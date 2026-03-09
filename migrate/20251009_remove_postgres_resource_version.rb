# frozen_string_literal: true

Sequel.migration do
  revert do
    alter_table(:postgres_resource) do
      add_column :version, :postgres_version
    end
  end
end
