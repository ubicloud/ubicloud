# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:postgres_resource) do
      add_column :maintenance_window_start_at, :integer
      add_constraint :valid_maintenance_windows_start_at, maintenance_window_start_at: 0..23
    end
  end
end
