# frozen_string_literal: true

class UbiCli
  on("pg").run_on("reset-upgrade") do
    desc "Reset a failed major version upgrade of the PostgreSQL database"

    banner "ubi pg (location/pg-name | pg-id) reset-upgrade"

    run do
      id = sdk_object.reset_upgrade.id
      response("Reset of the failed upgrade scheduled for PostgreSQL database with id: #{id}")
    end
  end
end
