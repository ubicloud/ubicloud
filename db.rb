# frozen_string_literal: true

require "netaddr"
require "sequel/core"
require_relative "config"

DB = Sequel.connect(Config.clover_database_url, max_connections: Config.db_pool - 1, pool_timeout: Config.database_timeout).tap do |db|
  # Replace dangerous (for cidrs) Ruby IPAddr type that is otherwise
  # used by sequel_pg.  Has come up more than once in the bug tracker:
  #
  # https://github.com/jeremyevans/sequel_pg/issues?q=inet
  # https://github.com/jeremyevans/sequel_pg/issues/30
  # https://github.com/jeremyevans/sequel_pg/pull/37
  db.add_conversion_proc(650, NetAddr.method(:parse_net))
  db.add_conversion_proc(869, NetAddr.method(:parse_ip))
end

# Load Sequel Database/Global extensions here
# DB.extension :date_arithmetic
DB.extension :pg_json, :pg_auto_parameterize, :pg_timestamptz, :pg_range
Sequel.extension :pg_range_ops
