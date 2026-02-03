# frozen_string_literal: true

UbiCli.on("pg").run_on("recycle") do
  desc "Request recycle of primary"

  banner "ubi pg (location/pg-name | pg-id) recycle"

  run do
    id = sdk_object.recycle.id
    response("Recycle requested for PostgreSQL database with id #{id}")
  end
end
