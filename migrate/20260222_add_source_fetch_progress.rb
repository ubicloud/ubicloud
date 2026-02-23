# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:vm_storage_volume) do
      add_column :source_fetch_total, Integer
      add_column :source_fetch_fetched, Integer
    end
  end
end
