# frozen_string_literal: true

class UbiCli
  on("pg").run_on("cancel-upgrade") do
    desc "Cancel a failed major version upgrade of the PostgreSQL database"

    banner "ubi pg (location/pg-name | pg-id) cancel-upgrade"

    run do
      id = sdk_object.cancel_upgrade.id
      response("Scheduled cancel of the failed upgrade of PostgreSQL database with id #{id}.")
    end
  end
end
