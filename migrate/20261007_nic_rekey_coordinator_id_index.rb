# frozen_string_literal: true

Sequel.migration do
  no_transaction

  change do
    alter_table(:nic) do
      add_index :rekey_coordinator_id, where: Sequel.~(rekey_coordinator_id: nil), name: :nic_rekey_coordinator_id_not_null_idx, concurrently: true
    end
  end
end
