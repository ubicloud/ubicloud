# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:vm_pool) do
      add_column :storage_encrypted, :bool, default: false, null: false
      add_column :storage_skip_sync, :bool, default: false, null: false
    end
  end
end
