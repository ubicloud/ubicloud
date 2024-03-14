# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:vm_pool) do
      set_column_default(:storage_encrypted, true)
    end

    run "UPDATE vm_pool SET storage_encrypted = true"
  end
end
