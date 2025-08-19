# frozen_string_literal: true

UbiCli.on("pg").run_on("remove-pgbouncer-config-entries") do
  desc "Remove pgbouncer configuration entries from a PostgreSQL database"

  banner "ubi pg (location/pg-name | pg-id) remove-pgbouncer-config-entries key [...]"

  args(1..)

  run do |args, _, cmd|
    config_entries_response(sdk_object.update_pgbouncer_config(**args.to_h { [it, nil] }), body: ["Updated pgbouncer config:\n"])
  end
end
