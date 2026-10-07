# frozen_string_literal: true

Sequel.migration do
  no_transaction

  change do
    alter_table(:vm_host_cpu) do
      add_index :vm_host_slice_id, concurrently: true
    end
  end
end
