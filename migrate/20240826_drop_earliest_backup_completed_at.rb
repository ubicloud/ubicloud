# frozen_string_literal: true

Sequel.migration do
  up do
    alter_table(:postgres_timeline) do
      drop_column :earliest_backup_completed_at
    end
  end

  down do
    alter_table(:postgres_timeline) do
      add_column :earliest_backup_completed_at, :timestamptz
    end
  end
end
