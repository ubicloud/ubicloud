# frozen_string_literal: true

Sequel.migration do
  revert do
    alter_table(:vm_storage_volume) do
      add_column :skip_sync, :bool, default: false, null: false
    end
    alter_table(:vm_pool) do
      add_column :storage_skip_sync, :bool, default: false, null: false
    end
  end
end
