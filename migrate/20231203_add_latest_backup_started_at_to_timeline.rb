# frozen_string_literal: true

Sequel.migration do
  up do
    alter_table(:postgres_timeline) do
      add_column :latest_backup_started_at, :timestamptz
    end

    run "UPDATE postgres_timeline SET latest_backup_started_at = last_backup_started_at"
  end

  down do
    alter_table(:postgres_timeline) do
      drop_column :latest_backup_started_at
    end
  end
end
