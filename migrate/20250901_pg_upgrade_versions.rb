# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:postgres_server) do
      add_column :version, :postgres_version, null: false, default: "16"
    end
  end

  change do
    alter_table(:postgres_resource) do
      add_column :desired_version, :postgres_version, null: false, default: "16"
    end

    run "UPDATE postgres_resource SET desired_version = version"
  end
end
