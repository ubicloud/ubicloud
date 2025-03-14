# frozen_string_literal: true

UbiCli.on("pg").run_on("delete-metric-destination") do
  desc "Delete a PostgreSQL metric destination"

  banner "ubi pg (location/pg-name | pg-id) delete-metric-destination md-id"

  args 1

  run do |ubid|
    if ubid.include?("/")
      raise Rodish::CommandFailure, "invalid metric destination id format"
    end

    delete(pg_path("/metric-destination/#{ubid}")) do |data|
      ["Metric destination, if it exists, has been scheduled for deletion"]
    end
  end
end
