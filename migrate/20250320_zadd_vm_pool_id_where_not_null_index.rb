# frozen_string_literal: true

Sequel.migration do
  no_transaction

  up do
    drop_index :vm, :pool_id, concurrently: true
    add_index :vm, [:pool_id], where: Sequel.~(pool_id: nil), concurrently: true
  end
end
