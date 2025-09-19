# frozen_string_literal: true

Sequel.migration do
  up do
    alter_table(:postgres_server) do
      add_column :version, :postgres_version
    end
  end

  down do
    alter_table(:postgres_server) do
      drop_column :version
    end
  end
end
