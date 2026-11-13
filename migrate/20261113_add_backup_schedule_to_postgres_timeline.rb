# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:postgres_timeline) do
      add_column :backup_window_start_at, :smallint
      add_column :backup_retention_days, :smallint, null: false, default: 7
      add_constraint :valid_backup_window_start_at, backup_window_start_at: 0..23
      add_constraint :valid_backup_period_hours, backup_period_hours: 1..168
      add_constraint :valid_backup_retention_days, backup_retention_days: 1..35
    end
  end
end
