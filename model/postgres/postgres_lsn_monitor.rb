# frozen_string_literal: true

require_relative "../../model"

class PostgresLsnMonitor < Sequel::Model(POSTGRES_MONITOR_DB[:postgres_lsn_monitor])
end
