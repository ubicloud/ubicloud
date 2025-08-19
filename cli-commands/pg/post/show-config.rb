# frozen_string_literal: true

UbiCli.on("pg").run_on("show-config") do
  desc "Show configuration for a PostgreSQL database"

  banner "ubi pg (location/pg-name | pg-id) show-config"

  run do
    body = []
    sdk_object.config.each do |k, v|
      body << k.to_s << "=" << v.to_s << "\n"
    end
    response(body)
  end
end
