# frozen_string_literal: true

class UbiCli
  on("pg").run_on("upgrade") do
    desc "Schedule a major version upgrade of the PostgreSQL database"

    options("ubi pg (location/pg-name | pg-id) upgrade [options]", key: :pg_upgrade) do
      on("-v", "--version=version", Option::POSTGRES_VERSION_OPTIONS, "target version (default: next major version)")
    end
    help_option_values("Version:", Option::POSTGRES_VERSION_OPTIONS)

    run do |opts|
      id = sdk_object.upgrade(target_version: opts[:pg_upgrade][:version]).id
      response("Scheduled major version upgrade of PostgreSQL database with id #{id} to version #{sdk_object.target_version}.")
    end
  end
end
