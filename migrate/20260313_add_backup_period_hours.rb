# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:postgres_timeline) do
      add_column :backup_period_hours, :smallint, null: false, default: 24
    end
  end
end
