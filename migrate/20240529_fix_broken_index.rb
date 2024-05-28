# frozen_string_literal: true

Sequel.migration do
  no_transaction

  up do
    alter_table(:billing_record) do
      drop_index :resource_id, concurrently: true
      add_index :resource_id, concurrently: true
    end
  end
end
