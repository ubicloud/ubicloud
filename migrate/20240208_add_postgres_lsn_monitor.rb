# frozen_string_literal: true

Sequel.migration do
  change do
    create_table(:postgres_lsn_monitor, unlogged: true) do
      column :postgres_server_id, :uuid, primary_key: true, null: false
      column :last_known_lsn, :pg_lsn
    end
  end
end
