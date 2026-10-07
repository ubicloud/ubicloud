# frozen_string_literal: true

Sequel.migration do
  no_transaction

  change do
    alter_table(:vm_storage_volume) do
      add_index :remote_storage_server_id, where: Sequel.~(remote_storage_server_id: nil), name: :vm_storage_volume_remote_storage_server_id_not_null_idx, concurrently: true
    end
  end
end
