# frozen_string_literal: true

Sequel.migration do
  no_transaction

  change do
    alter_table(:account_identities) do
      add_index :account_id, concurrently: true
    end
  end
end
