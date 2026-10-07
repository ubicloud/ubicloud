# frozen_string_literal: true

Sequel.migration do
  no_transaction

  change do
    alter_table(:vm_storage_volume) do
      add_index :vhost_block_backend_id, concurrently: true
    end
  end
end
