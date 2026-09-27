# frozen_string_literal: true

Sequel.migration do
  up do
    alter_table(:remote_storage_server) do
      set_column_allow_null :source_vm_storage_volume_id
      add_foreign_key :source_detachable_volume_id, :detachable_volume, type: :uuid
      add_unique_constraint :source_detachable_volume_id, name: :remote_storage_server_source_detachable_volume_id_key
      add_constraint(:remote_storage_server_single_source,
        "(source_vm_storage_volume_id IS NOT NULL)::int + (source_detachable_volume_id IS NOT NULL)::int = 1")
    end
  end

  down do
    alter_table(:remote_storage_server) do
      drop_constraint :remote_storage_server_single_source
      drop_constraint :remote_storage_server_source_detachable_volume_id_key
      drop_foreign_key :source_detachable_volume_id
      set_column_not_null :source_vm_storage_volume_id
    end
  end
end
