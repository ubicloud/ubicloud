# frozen_string_literal: true

UbiCli.on("pg").run_on("delete-metric-destination") do
  desc "Delete a PostgreSQL metric destination"

  banner "ubi pg (location/pg-name | pg-id) delete-metric-destination md-id"

  args 1

  run do |ubid|
    check_no_slash(ubid, "invalid metric destination id format")
    sdk_object.delete_metric_destination(ubid)
    response("Metric destination, if it exists, has been scheduled for deletion")
  end
end
