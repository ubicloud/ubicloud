# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:postgres_timeline) do
      # Where the newest completed backup ended, in "X/Y" form for lsn2int.
      add_column :latest_backup_lsn, :text, collate: '"C"'
      add_column :latest_backup_wal_timeline_id, :integer
    end
  end
end
