# frozen_string_literal: true

UbiCli.on("pg").run_on("modify") do
  desc "Modify a PostgreSQL database cluster"

  options("ubi pg (location/pg-name | pg-id) modify [options]", key: :pg_modify) do
    on("-h", "--ha-type=type", Option::POSTGRES_HA_OPTIONS.keys, "replication type")
    on("-s", "--size=size", Option::POSTGRES_SIZE_OPTIONS.keys, "server size")
    on("-S", "--storage-size=size", Option::POSTGRES_STORAGE_SIZE_OPTIONS, "storage size GB")
    on("-t", "--tags=tags", "tags (e.g. key1=value1,key2=value2)")
  end
  help_option_values("Replication Type:", Option::POSTGRES_HA_OPTIONS.keys)
  help_option_values("Size:", Option::POSTGRES_SIZE_OPTIONS.keys)
  help_option_values("Storage Size:", Option::POSTGRES_STORAGE_SIZE_OPTIONS)

  run do |opts, cmd|
    params = underscore_keys(opts[:pg_modify])
    pg_tags_to_hash(params, cmd)
    id = sdk_object.modify(**params).id
    response("Modified PostgreSQL database with id: #{id}")
  end
end
