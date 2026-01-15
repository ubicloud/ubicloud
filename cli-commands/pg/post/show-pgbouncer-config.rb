# frozen_string_literal: true

UbiCli.on("pg").run_on("show-pgbouncer-config") do
  desc "Show pgbouncer configuration for a PostgreSQL database"

  banner "ubi pg (location/pg-name | pg-id) show-pgbouncer-config"

  run do
    config_entries_response(sdk_object.pgbouncer_config)
  end
end
