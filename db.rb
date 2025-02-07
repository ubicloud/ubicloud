# frozen_string_literal: true

require "netaddr"
require "sequel/core"
require_relative "config"
require_relative "lib/util"

db_ca_bundle_filename = File.join(Dir.pwd, "var", "ca_bundles", "db_ca_bundle.crt")
Util.safe_write_to_file(db_ca_bundle_filename, Config.clover_database_root_certs)
max_connections = Config.db_pool - 1
max_connections = 1 if ENV["SHARED_CONNECTION"] == "1"
if Config.development? || (Config.test? && ENV["CLOVER_FREEZE"] == "1")
  treat_string_list_as_text_array = true
  pg_auto_parameterize_min_array_size = 1
end
DB = Sequel.connect(Config.clover_database_url, max_connections:, pool_timeout: Config.database_timeout, treat_string_list_as_text_array:, pg_auto_parameterize_min_array_size:).tap do |db|
  # Replace dangerous (for cidrs) Ruby IPAddr type that is otherwise
  # used by sequel_pg.  Has come up more than once in the bug tracker:
  #
  # https://github.com/jeremyevans/sequel_pg/issues?q=inet
  # https://github.com/jeremyevans/sequel_pg/issues/30
  # https://github.com/jeremyevans/sequel_pg/pull/37
  db.add_conversion_proc(650, NetAddr.method(:parse_net))
  db.add_conversion_proc(869, NetAddr.method(:parse_ip))
end

postgres_monitor_db_ca_bundle_filename = File.join(Dir.pwd, "var", "ca_bundles", "postgres_monitor_db.crt")
Util.safe_write_to_file(postgres_monitor_db_ca_bundle_filename, Config.postgres_monitor_database_root_certs)
begin
  POSTGRES_MONITOR_DB = Sequel.connect(Config.postgres_monitor_database_url, max_connections: Config.db_pool, pool_timeout: Config.database_timeout) if Config.postgres_monitor_database_url
rescue Sequel::DatabaseConnectionError => ex
  Clog.emit("Failed to connect to Postgres Monitor database") { {database_connection_failed: {exception: Util.exception_to_hash(ex)}} }
end

# Load Sequel Database/Global extensions here
# DB.extension :date_arithmetic
DB.extension :pg_array, :pg_json, :pg_auto_parameterize, :pg_auto_parameterize_in_array, :pg_timestamptz, :pg_range
Sequel.extension :pg_range_ops, :pg_json_ops

DB.extension :pg_schema_caching
DB.extension :index_caching
DB.load_schema_cache?("cache/schema.cache")
DB.load_index_cache?("cache/index.cache")

DB.extension :temporarily_release_connection if ENV["SHARED_CONNECTION"] == "1"
DB.extension :query_blocker if Config.test? && ENV["CLOVER_FREEZE"] == "1"
