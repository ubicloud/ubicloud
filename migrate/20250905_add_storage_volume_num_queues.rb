# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:vm_storage_volume) do
      add_column :vring_workers, Integer, null: true
    end
  end
end
