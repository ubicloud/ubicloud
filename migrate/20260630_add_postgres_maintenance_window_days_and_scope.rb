# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:postgres_resource) do
      add_column :maintenance_window_days, :smallint
      add_constraint :valid_maintenance_window_days, maintenance_window_days: 0..127
      add_column :maintenance_window_platform_only, :boolean, null: false, default: false
    end
  end
end
