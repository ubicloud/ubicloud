# frozen_string_literal: true

UbiCli.on("pg").run_on("remove-config-entries") do
  desc "Remove configuration entries from a PostgreSQL database"

  banner "ubi pg (location/pg-name | pg-id) remove-config-entries key [...]"

  args(1..)

  run do |args, _, cmd|
    config_entries_response(sdk_object.update_config(**args.to_h { [it, nil] }), body: ["Updated config:\n"])
  end
end
