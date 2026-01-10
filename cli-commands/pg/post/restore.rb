# frozen_string_literal: true

UbiCli.on("pg").run_on("restore") do
  desc "Restore a PostgreSQL database backup to a new database"

  options("ubi pg (location/pg-name | pg-id) restore [options] new-db-name restore-time", key: :pg_restore) do
    on("-c", "--pg-config=config", "postgres config (e.g. key1=value1,key2=value2)")
    on("-u", "--pgbouncer-config=config", "pgbouncer config (e.g. key1=value1,key2=value2)")
    on("-t", "--tags=tags", "tags (e.g. key1=value1,key2=value2)")
  end

  args 2

  run do |name, restore_target, opts, cmd|
    params = underscore_keys(opts[:pg_restore])
    pg_tags_to_hash(params, cmd)
    params_to_hash(params, :pg_config, "config", cmd)
    params_to_hash(params, :pgbouncer_config, "pgbouncer config", cmd)
    id = sdk_object.restore(name:, restore_target:, **params).id
    response("Restored PostgreSQL database scheduled for creation with id: #{id}")
  end
end
