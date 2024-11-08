# frozen_string_literal: true

require_relative "../../model"

class PostgresLsnMonitor < Sequel::Model(POSTGRES_MONITOR_DB[:postgres_lsn_monitor])
end

# Table: postgres_lsn_monitor
# Columns:
#  postgres_server_id | uuid   | PRIMARY KEY
#  last_known_lsn     | pg_lsn |
# Indexes:
#  postgres_lsn_monitor_pkey | PRIMARY KEY btree (postgres_server_id)
