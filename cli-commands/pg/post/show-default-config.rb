# frozen_string_literal: true

UbiCli.on("pg").run_on("show-default-config") do
  desc "Show default configuration for a PostgreSQL database"

  banner "ubi pg (location/pg-name | pg-id) show-default-config"

  run do
    config_entries_response(sdk_object.default_pg_config)
  end
end
