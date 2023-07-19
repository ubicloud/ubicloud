# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:vm_host) do
      add_column :total_storage_gib, Integer
      add_column :available_storage_gib, Integer
    end
  end
end
