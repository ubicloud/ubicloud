# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:postgres_resource) do
      add_column :maintenance_window_start_at, :integer
    end
  end
end
