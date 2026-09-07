# frozen_string_literal: true

require_relative "../../model"

class PostgresBackupMeteringState < Sequel::Model
end

# Table: postgres_backup_metering_state
# Columns:
#  id                  | uuid                     | PRIMARY KEY
#  swept_at            | timestamp with time zone |
#  cursor              | text                     |
#  wal_bytes           | bigint                   |
#  wal_day_bytes       | jsonb                    | NOT NULL DEFAULT '{}'::jsonb
#  backup_bytes        | bigint                   |
#  backup_walked_at    | timestamp with time zone |
#  backup_started_seen | timestamp with time zone |
#  boundary_day        | date                     |
#  boundary_probed_at  | timestamp with time zone |
# Indexes:
#  postgres_backup_metering_state_pkey | PRIMARY KEY btree (id)
# Foreign key constraints:
#  postgres_backup_metering_state_id_fkey | (id) REFERENCES postgres_timeline(id) ON DELETE CASCADE
