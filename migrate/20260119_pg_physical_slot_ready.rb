# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:postgres_server) do
      add_column :physical_slot_ready, :boolean, null: false, default: false
    end
  end
end
