# frozen_string_literal: true

Sequel.migration do
  no_transaction

  revert do
    alter_table(:postgres_server) do
      add_index :resource_id, unique: true, where: Sequel.~(representative_at: nil), concurrently: true
    end
  end
end
