# frozen_string_literal: true

UbiCli.on("pg").run_on("create") do
  desc "Create a PostgreSQL database"

  options("ubi pg location/pg-name create [options]", key: :pg_create) do
    on("-f", "--flavor=type", "flavor")
    on("-h", "--ha-type=type", "replication type")
    on("-s", "--size=size", "server size")
    on("-S", "--storage-size=size", "storage size GB")
    on("-v", "--version=version", "PostgreSQL version")
  end
  help_option_values("Flavor:", Option::POSTGRES_VERSION_OPTIONS.keys)
  help_option_values("Replication Type:", Option::PostgresHaOptions.map(&:name))
  help_option_values("Size:", Option::PostgresSizes.map(&:name).uniq)
  help_option_values("Storage Size:", Option::PostgresSizes.map(&:storage_size_options).flatten.map(&:to_i).uniq.sort)
  help_option_values("Version:", Option::POSTGRES_VERSION_OPTIONS)

  run do |opts|
    params = underscore_keys(opts[:pg_create])
    id = sdk.postgres.create(location: @location, name: @name, **params).id
    response("PostgreSQL database created with id: #{id}")
  end
end
