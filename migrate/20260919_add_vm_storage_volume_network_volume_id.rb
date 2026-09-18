# frozen_string_literal: true

Sequel.migration do
  # Adding the column is cheap, but building its index is not: vm_storage_volume
  # is large, and a unique constraint added along with the column would hold an
  # exclusive lock for the whole build. Add the column first, then the index
  # concurrently.
  no_transaction

  change do
    alter_table(:vm_storage_volume) do
      add_foreign_key :network_volume_id, :network_volume, type: :uuid
    end

    # A single attachment prevents concurrent ext4 mounts.
    alter_table(:vm_storage_volume) do
      add_index :network_volume_id, unique: true, concurrently: true
    end
  end
end
