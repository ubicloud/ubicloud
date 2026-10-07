# frozen_string_literal: true

Sequel.migration do
  no_transaction

  change do
    alter_table(:github_runner) do
      add_index :repository_id, concurrently: true
    end
  end
end
