# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:postgres_server) do
      add_column :archived_wal_floor, String, collate: '"C"'
    end
  end
end
