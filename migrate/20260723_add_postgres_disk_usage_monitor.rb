# frozen_string_literal: true

Sequel.migration do
  change do
    create_table(:postgres_disk_usage_monitor, unlogged: true) do
      column :postgres_server_id, :uuid, primary_key: true, null: false
      column :data_disk_usage_percent, :smallint
      column :observed_at, :timestamptz
    end
  end
end
