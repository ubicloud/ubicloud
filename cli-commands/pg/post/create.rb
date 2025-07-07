# frozen_string_literal: true

UbiCli.on("pg").run_on("create") do
  desc "Create a PostgreSQL database"

  options("ubi pg location/pg-name create [options]", key: :pg_create) do
    on("-f", "--flavor=type", Option::POSTGRES_FLAVOR_OPTIONS.keys, "flavor")
    on("-h", "--ha-type=type", Option::POSTGRES_HA_OPTIONS.keys, "replication type")
    on("-s", "--size=size", Option::POSTGRES_SIZE_OPTIONS.keys, "server size")
    on("-S", "--storage-size=size", Option::POSTGRES_STORAGE_SIZE_OPTIONS, "storage size GB")
    on("-v", "--version=version", Option::POSTGRES_VERSION_OPTIONS, "PostgreSQL version")
  end
  help_option_values("Flavor:", Option::POSTGRES_FLAVOR_OPTIONS.keys)
  help_option_values("Replication Type:", Option::POSTGRES_HA_OPTIONS.keys)
  help_option_values("Size:", Option::POSTGRES_SIZE_OPTIONS.keys)
  help_option_values("Storage Size:", Option::POSTGRES_STORAGE_SIZE_OPTIONS)
  help_option_values("Version:", Option::POSTGRES_VERSION_OPTIONS)

  run do |opts|
    params = underscore_keys(opts[:pg_create])
    id = sdk.postgres.create(location: @location, name: @name, **params).id
    response("PostgreSQL database created with id: #{id}")
  end
end
