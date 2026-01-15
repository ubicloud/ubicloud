# frozen_string_literal: true

UbiCli.on("pg").run_on("add-pgbouncer-config-entries") do
  desc "Add pgbouncer configuration entries to a PostgreSQL database"

  banner "ubi pg (location/pg-name | pg-id) add-pgbouncer-config-entries key=value [...]"

  args(1..)

  run do |args, _, cmd|
    config_entries_response(sdk_object.update_pgbouncer_config(**config_entries_to_hash(args, cmd)), body: ["Updated pgbouncer config:\n"])
  end
end
