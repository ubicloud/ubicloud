# frozen_string_literal: true

UbiCli.on("pg").run_on("create-read-replica") do
  desc "Create a read replica for a PostgreSQL database"

  options("ubi pg (location/pg-name | pg-id) create-read-replica name [options]", key: :pg_create_read_replica) do
    on("-t", "--tags=tags", "tags (e.g. key1=value1,key2=value2)")
  end

  args 1

  run do |name, opts, cmd|
    params = underscore_keys(opts[:pg_create_read_replica])
    pg_tags_to_hash(params, cmd)
    id = sdk_object.create_read_replica(name, **params).id
    response("Read replica for PostgreSQL database created with id: #{id}")
  end
end
