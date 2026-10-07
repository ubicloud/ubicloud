# frozen_string_literal: true

Sequel.migration do
  no_transaction

  change do
    alter_table(:nic) do
      add_index :vm_id, concurrently: true
    end
  end
end
