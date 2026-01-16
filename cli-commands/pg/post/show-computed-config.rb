# frozen_string_literal: true

UbiCli.on("pg").run_on("show-computed-config") do
  desc "Show computed configuration for a PostgreSQL database"

  banner "ubi pg (location/pg-name | pg-id) show-computed-config"

  run do
    config_entries_response(sdk_object.computed_config)
  end
end
