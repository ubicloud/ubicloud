# frozen_string_literal: true

UbiCli.on("pg").run_on("add-metric-destination") do
  desc "Add a PostgreSQL metric destination"

  options("ubi pg (location/pg-name | pg-id) add-metric-destination [options] username password url", key: :md_opts) do
    on("-a", "--auth-type=type", %w[basic bearer], "authentication type (default: basic)")
  end

  args(2..3)

  run do |argv, opts|
    params = underscore_keys(opts[:md_opts])
    if argv.length == 3
      username, password, url = argv
      params[:username] ||= username
    else
      url, password = argv
    end
    data = sdk_object.add_metric_destination(url:, password:, **params)
    body = []
    body << "Metric destination added to PostgreSQL database.\n"
    body << "Current metric destinations:\n"
    data[:metric_destinations].each_with_index do |md, i|
      body << "  " << (i + 1).to_s << ": " << md[:id] << "  " << md[:auth_type]
      body << "  " << md[:username] if md[:auth_type] == "basic"
      body << "  " << md[:url] << "\n"
    end
    response(body)
  end
end
