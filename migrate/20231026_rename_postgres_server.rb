# frozen_string_literal: true

Sequel.migration do
  change do
    rename_table(:postgres_server, :postgres_resource)
  end
end
