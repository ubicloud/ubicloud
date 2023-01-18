begin
  require_relative ".env"
rescue LoadError
end

require "sequel/core"

DB = Sequel.connect(Config.clover_database_url)

# Load Sequel Database/Global extensions here
# DB.extension :date_arithmetic
DB.extension :pg_auto_parameterize if DB.adapter_scheme == :postgres && Sequel::Postgres::USES_PG
