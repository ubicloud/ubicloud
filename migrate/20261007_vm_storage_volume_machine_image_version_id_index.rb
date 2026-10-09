# frozen_string_literal: true

Sequel.migration do
  no_transaction

  change do
    alter_table(:vm_storage_volume) do
      add_index :machine_image_version_id, where: Sequel.~(machine_image_version_id: nil), name: :vm_storage_volume_machine_image_version_id_not_null_idx, concurrently: true
    end
  end
end
