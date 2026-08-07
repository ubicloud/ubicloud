# frozen_string_literal: true

class UbiCli
  on("pg").run_on("add-bearer-metric-destination") do
    desc "Add a PostgreSQL metric destination using bearer token authentication"

    banner "ubi pg (location/pg-name | pg-id) add-bearer-metric-destination url token [header_name=value [...]]"

    args(2..)

    run do |args, _, cmd|
      url, token, *extra_args = args
      headers = kv_entries_to_hash(extra_args, cmd)
      metric_destinations_response(sdk_object.add_bearer_metric_destination(url:, token:, headers:))
    end
  end
end
