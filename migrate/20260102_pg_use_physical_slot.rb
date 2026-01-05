# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:postgres_server) do
      add_column :use_physical_slot, :boolean, null: false, default: false
    end
  end
end
