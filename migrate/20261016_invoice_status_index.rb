# frozen_string_literal: true

Sequel.migration do
  no_transaction

  change do
    add_index :invoice, :status, concurrently: true
  end
end
