# frozen_string_literal: true

Sequel.migration do
  revert do
    alter_table(:vm_pool) do
      add_column :storage_encrypted, :bool, default: true, null: false
    end
  end
end
