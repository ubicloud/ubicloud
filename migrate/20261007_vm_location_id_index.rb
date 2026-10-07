# frozen_string_literal: true

Sequel.migration do
  no_transaction

  change do
    alter_table(:vm) do
      add_index :location_id, concurrently: true
    end
  end
end
