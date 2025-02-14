# frozen_string_literal: true

UbiRodish.on("pg").run_on("create") do
  options("ubi pg location/pg_name create [options]", key: :pg_create) do
    on("-f", "--flavor=type", "flavor (standard, paradedb, lantern)")
    on("-h", "--ha_type=type", "replication type (none, async, sync)")
    on("-s", "--size=size", "server size (standard-{2,4,8,16,30,60})")
    on("-S", "--storage_size=size", "storage size GB (64, 128, 256)")
    on("-v", "--version=version", "PostgreSQL version (16, 17)")
  end

  run do |opts|
    params = opts[:pg_create].transform_keys(&:to_s)
    params["size"] ||= "standard-2"
    post(project_path("location/#{@location}/postgres/#{@name}"), params) do |data|
      ["PostgreSQL database created with id: #{data["id"]}"]
    end
  end
end
