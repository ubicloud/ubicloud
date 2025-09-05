# frozen_string_literal: true

Sequel.migration do
  up do
    alter_table(:postgres_server) do
      add_column :version, :postgres_version, null: false, default: "16"
    end

    alter_table(:postgres_resource) do
      add_column :desired_version, :postgres_version, null: false, default: "16"
    end

    run "UPDATE postgres_resource SET desired_version = version"
  end

  down do
    alter_table(:postgres_server) do
      drop_column :version
    end

    alter_table(:postgres_resource) do
      drop_column :desired_version
    end
  end
end
