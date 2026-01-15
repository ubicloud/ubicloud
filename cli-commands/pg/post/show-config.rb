# frozen_string_literal: true

UbiCli.on("pg").run_on("show-config") do
  desc "Show configuration for a PostgreSQL database"

  banner "ubi pg (location/pg-name | pg-id) show-config"

  run do
    config_entries_response(sdk_object.config)
  end
end
