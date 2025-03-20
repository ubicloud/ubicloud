# frozen_string_literal: true

Sequel.migration do
  no_transaction

  change do
    add_index :vm, [:pool_id], concurrently: true
  end
end
