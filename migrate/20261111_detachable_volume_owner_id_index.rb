# frozen_string_literal: true

Sequel.migration do
  no_transaction

  change do
    add_index :detachable_volume, :owner_id, name: :detachable_volume_owner_id_idx, concurrently: true
  end
end
