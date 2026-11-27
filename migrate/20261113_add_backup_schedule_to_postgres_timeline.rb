# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:postgres_timeline) do
      add_column :backup_window_start_at, :smallint
      add_column :backup_retention_days, :smallint, null: false, default: 7
    end
  end
end
