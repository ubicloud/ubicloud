# frozen_string_literal: true

Sequel.migration do
  up do
    run "UPDATE postgres_server SET version = postgres_resource.version FROM postgres_resource WHERE postgres_server.version IS NULL AND postgres_resource.id = postgres_server.resource_id"

    alter_table(:postgres_server) do
      set_column_not_null :version
    end
  end

  down do
    alter_table(:postgres_server) do
      set_column_null :version
    end
  end
end
