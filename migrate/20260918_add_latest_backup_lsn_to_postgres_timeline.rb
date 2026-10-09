# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:postgres_timeline) do
      # Where the newest completed backup started, which is where a restore
      # from it begins replaying WAL.
      add_column :latest_backup_lsn, :pg_lsn
    end
  end
end
