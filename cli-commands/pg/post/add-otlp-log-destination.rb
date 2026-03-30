# frozen_string_literal: true

UbiCli.on("pg").run_on("add-otlp-log-destination") do
  desc "Add an OTLP HTTP log destination to a PostgreSQL database"

  banner "ubi pg (location/pg-name | pg-id) add-otlp-log-destination name url [header_name=value [...]]"

  args(2..)

  run do |args, _, cmd|
    name, url, *extra_args = args
    headers = kv_entries_to_hash(extra_args, cmd)
    ld = sdk_object.add_otlp_log_destination(name:, url:, headers:)
    response("Log destination added to PostgreSQL database.\n  id: #{ld[:id]}\n")
  end
end
