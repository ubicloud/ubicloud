# frozen_string_literal: true

UbiCli.on("pg").run_on("show-pgbouncer-config") do
  desc "Show pgbouncer configuration for a PostgreSQL database"

  banner "ubi pg (location/pg-name | pg-id) show-pgbouncer-config"

  run do
    body = []
    sdk_object.pgbouncer_config.sort.each do |k, v|
      body << k.to_s << "=" << v.to_s << "\n"
    end
    response(body)
  end
end
