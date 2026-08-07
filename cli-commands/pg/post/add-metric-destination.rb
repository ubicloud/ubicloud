# frozen_string_literal: true

class UbiCli
  on("pg").run_on("add-metric-destination") do
    desc "Add a PostgreSQL metric destination"

    banner "ubi pg (location/pg-name | pg-id) add-metric-destination username password url"

    args 3

    run do |username, password, url|
      metric_destinations_response(sdk_object.add_metric_destination(username:, password:, url:))
    end
  end
end
