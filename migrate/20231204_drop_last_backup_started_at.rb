# frozen_string_literal: true

Sequel.migration do
  up do
    alter_table(:postgres_timeline) do
      drop_column :last_backup_started_at
    end
  end

  down do
    alter_table(:postgres_timeline) do
      add_column :last_backup_started_at, :timestamptz

      run "UPDATE postgres_timeline SET last_backup_started_at = latest_backup_started_at"
    end
  end
end
