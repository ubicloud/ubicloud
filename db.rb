# frozen_string_literal: true

require "netaddr"
require "sequel/core"
require_relative "config"

DB = Sequel.connect(Config.clover_database_url).tap do |db|
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
DB.extension :pg_json
DB.extension :pg_auto_parameterize if DB.adapter_scheme == :postgres && Sequel::Postgres::USES_PG
