# frozen_string_literal: true

Sequel.migration do
  up do
    alter_table(:postgres_server) do
      drop_column :physical_slot_ready
    end
  end

  down do
    alter_table(:postgres_server) do
      add_column :physical_slot_ready, :boolean, null: false, default: false
    end
  end
end
