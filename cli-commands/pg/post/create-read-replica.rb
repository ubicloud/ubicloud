# frozen_string_literal: true

class UbiCli
  on("pg").run_on("create-read-replica") do
    desc "Create a read replica for a PostgreSQL database"

    options("ubi pg (location/pg-name | pg-id) create-read-replica [options] name", key: :pg_create_read_replica) do
      on("-c", "--pg-config=config", "postgres config (e.g key1=value1,key2=value2)")
      on("-u", "--pgbouncer-config=config", "pgbouncer config (e.g. key1=value1,key2=value2)")
      on("-t", "--tags=tags", "tags (e.g. key1=value1,key2=value2)")
      on("-i", "--ipv4-range=cidr", "private IPv4 range of the created private subnet (e.g. 10.20.0.0/20)")
    end

    args 1

    run do |name, opts, cmd|
      params = underscore_keys(opts[:pg_create_read_replica])
      params[:private_subnet_ipv4_range] = params.delete(:ipv4_range) if params[:ipv4_range]
      pg_tags_to_hash(params, cmd)
      params_to_hash(params, :pg_config, "config", cmd)
      params_to_hash(params, :pgbouncer_config, "pgbouncer config", cmd)
      id = sdk_object.create_read_replica(name, **params).id
      response("Read replica for PostgreSQL database created with id: #{id}")
    end
  end
end
