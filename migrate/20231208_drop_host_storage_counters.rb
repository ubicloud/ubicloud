# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:vm_host) do
      drop_column :available_storage_gib
      drop_column :total_storage_gib
    end
  end
end
