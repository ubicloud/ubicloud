# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:postgres_timeline) do
      add_column :earliest_backup_completed_at, :timestamptz
    end
  end
end
