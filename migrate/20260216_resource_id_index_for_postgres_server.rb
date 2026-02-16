# frozen_string_literal: true

Sequel.migration do
  no_transaction

  change do
    alter_table(:postgres_server) do
      add_index :resource_id, concurrently: true
    end
  end
end
