# frozen_string_literal: true

Sequel.migration do
  no_transaction

  change do
    alter_table(:assigned_vm_address) do
      add_index :address_id, concurrently: true
    end
  end
end
