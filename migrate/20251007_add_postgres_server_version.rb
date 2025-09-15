# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:postgres_server) do
      add_column :version, :postgres_version
    end

    alter_table(:postgres_resource) do
      add_column :target_version, :postgres_version
    end
  end
end
