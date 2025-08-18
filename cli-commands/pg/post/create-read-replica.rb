# frozen_string_literal: true

UbiCli.on("pg").run_on("create-read-replica") do
  desc "Create a read replica for a PostgreSQL database"

  banner "ubi pg (location/pg-name | pg-id) create-read-replica name"

  args 1

  run do |name|
    id = sdk_object.create_read_replica(name).id
    response("Read replica for PostgreSQL database created with id: #{id}")
  end
end
