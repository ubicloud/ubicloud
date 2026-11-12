# frozen_string_literal: true

class UbiCli
  on("pg").run_on("add-metric-destination") do
    desc "Add a PostgreSQL metric destination"

    banner "ubi pg (location/pg-name | pg-id) add-metric-destination username password url"

    args 3

    run do |username, password, url|
      logged_argv[-2] = "-"
      pg = sdk_object
      pg.add_metric_destination(username:, password:, url:)
      metric_destinations_response(pg)
    end
  end
end
