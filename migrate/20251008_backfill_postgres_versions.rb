# frozen_string_literal: true

Sequel.migration do
  up do
    run "UPDATE postgres_resource SET target_version = version WHERE target_version IS NULL"
    run "UPDATE postgres_server SET version = postgres_resource.target_version FROM postgres_resource WHERE postgres_server.version IS NULL AND postgres_resource.id = postgres_server.resource_id"

    alter_table(:postgres_server) do
      set_column_not_null :version
    end

    alter_table(:postgres_resource) do
      set_column_not_null :target_version
    end
  end

  down do
    alter_table(:postgres_server) do
      set_column_null :version
    end

    alter_table(:postgres_resource) do
      set_column_null :target_version
    end
  end
end
