# frozen_string_literal: true

UbiCli.on("pg").run_on("restart") do
  desc "Restart a PostgreSQL database cluster"

  banner "ubi pg (location/pg-name | pg-id) restart"

  run do
    id = sdk_object.restart.id
    response("Scheduled restart of PostgreSQL database with id #{id}")
  end
end
