# frozen_string_literal: true

UbiCli.on("pg").run_on("add-metric-destination") do
  desc "Add a PostgreSQL metric destination"

  banner "ubi pg (location/pg-name | pg-id) add-metric-destination username password url"

  args 3

  run do |username, password, url|
    data = sdk_object.add_metric_destination(username:, password:, url:)
    body = []
    body << "Metric destination added to PostgreSQL database.\n"
    body << "Current metric destinations:\n"
    data[:metric_destinations].each_with_index do |md, i|
      body << "  " << (i + 1).to_s << ": " << md[:id] << "  " << md[:username].to_s << "  " << md[:url] << "\n"
    end
    response(body)
  end
end
