# frozen_string_literal: true

Sequel.migration do
  no_transaction

  change do
    alter_table(:vm_storage_volume) do
      add_index :key_encryption_key_2_id, where: Sequel.~(key_encryption_key_2_id: nil), name: :vm_storage_volume_key_encryption_key_2_id_not_null_idx, concurrently: true
    end
  end
end
