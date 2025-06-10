# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:postgres_timeline) do
      add_column :cached_earliest_backup_at, :timestamptz, null: true, default: nil
    end
  end
end
