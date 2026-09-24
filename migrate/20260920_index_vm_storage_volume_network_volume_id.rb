# frozen_string_literal: true

Sequel.migration do
  # vm_storage_volume is large, and adding the index along with the column
  # would hold an exclusive lock for the whole build.
  no_transaction

  change do
    alter_table(:vm_storage_volume) do
      # Two concurrent ext4 mounts of one volume would corrupt it.
      add_index :network_volume_id, unique: true, concurrently: true
    end
  end
end
