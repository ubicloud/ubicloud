# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:vm) do
      add_column :maintenance_window_start_at, Integer
      add_column :maintenance_window_days_bitmask, :smallint, null: false, default: 0

      add_constraint :valid_maintenance_windows_start_at, maintenance_window_start_at: 0..23
      add_constraint :valid_maintenance_window_days_bitmask, maintenance_window_days_bitmask: 0..127
    end
  end
end
