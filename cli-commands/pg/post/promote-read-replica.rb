# frozen_string_literal: true

UbiCli.on("pg").run_on("promote-read-replica") do
  desc "Promote a read replica PostgreSQL database to a primary"

  banner "ubi pg (location/pg-name | pg-id) promote-read-replica"

  run do
    id = sdk_object.promote_read_replica.id
    response("Promoted PostgreSQL database with id #{id} from read replica to primary.")
  end
end
