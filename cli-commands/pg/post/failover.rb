# frozen_string_literal: true

UbiCli.on("pg").run_on("failover") do
  desc "Request failover of primary"

  banner "ubi pg (location/pg-name | pg-id) failover"

  run do
    id = sdk_object.failover.id
    response("Failover requested for PostgreSQL database with id #{id}")
  end
end
