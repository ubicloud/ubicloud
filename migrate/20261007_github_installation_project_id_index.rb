# frozen_string_literal: true

Sequel.migration do
  no_transaction

  change do
    alter_table(:github_installation) do
      add_index :project_id, concurrently: true
    end
  end
end
