# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:vm_storage_volume) do
      add_column :skip_sync, :bool, null: false, default: false
    end
  end
end
