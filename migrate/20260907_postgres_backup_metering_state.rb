# frozen_string_literal: true

Sequel.migration do
  change do
    create_table(:postgres_backup_metering_state) do
      foreign_key :id, :postgres_timeline, type: :uuid, primary_key: true, on_delete: :cascade
      column :swept_at, :timestamptz
      column :cursor, :text, collate: '"C"'
      column :wal_bytes, :Bignum
      column :wal_day_bytes, :jsonb, null: false, default: "{}"
      column :backup_bytes, :Bignum
      column :backup_walked_at, :timestamptz
      column :backup_started_seen, :timestamptz
      column :boundary_day, :date
      column :boundary_probed_at, :timestamptz
    end
  end
end
