# frozen_string_literal: true

Sequel.migration do
  no_transaction

  change do
    alter_table(:semaphore) do
      add_index :strand_id, concurrently: true
    end
  end
end
