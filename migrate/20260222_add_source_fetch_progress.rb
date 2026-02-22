# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:vm_storage_volume) do
      add_column :source_fetch_total, :integer
      add_column :source_fetch_fetched, :integer
    end
  end
end
