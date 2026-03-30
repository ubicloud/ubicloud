# frozen_string_literal: true

UbiCli.on("pg").run_on("delete-log-destination") do
  desc "Delete a PostgreSQL log destination"

  banner "ubi pg (location/pg-name | pg-id) delete-log-destination ld-id"

  args 1

  run do |ubid, _, cmd|
    check_no_slash(ubid, "invalid log destination id format", cmd)
    sdk_object.delete_log_destination(ubid)
    response("Log destination, if it exists, has been scheduled for deletion")
  end
end
