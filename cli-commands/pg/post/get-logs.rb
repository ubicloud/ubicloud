# frozen_string_literal: true

UbiCli.on("pg").run_on("get-logs") do
  desc "Fetch logs for a PostgreSQL database in CSV format"

  key = :pg_get_logs

  options("ubi pg (location/pg-name | pg-id) get-logs [options]", key:) do
    on("-s", "--start=time", "start time (RFC3339, default: 30 minutes ago)")
    on("-e", "--end=time", "end time (RFC3339, default: now)")
    on("--stream=stream", Option::POSTGRES_LOG_STREAM_OPTIONS, "filter by log stream")
    on("--server-role=role", Option::POSTGRES_LOG_SERVER_ROLE_OPTIONS, "filter by server role")
    on("--level=level", Option::POSTGRES_LOG_LEVEL_OPTIONS, "filter by log level")
    on("--pattern=regex", "regex pattern to match against log message")
    on("-l", "--limit=n", "number of log lines to return (default: 50, max: 500)", Integer)
    on("--pagination-key=key", "continue a previous search")
    on("-N", "--no-headers", "do not show headers")
  end
  help_option_values("Stream:", Option::POSTGRES_LOG_STREAM_OPTIONS)
  help_option_values("Server Role:", Option::POSTGRES_LOG_SERVER_ROLE_OPTIONS)
  help_option_values("Level:", Option::POSTGRES_LOG_LEVEL_OPTIONS)

  run do |opts|
    o = underscore_keys(opts[key])
    no_headers = o.delete(:no_headers)
    page = sdk_object.logs(**o.compact)

    body = format_paginated_csv(page, "ubi pg #{@location}/#{@name} get-logs", no_headers:, header_row: "Timestamp,ServerRole,Stream,Level,Message") do |log|
      "#{log[:timestamp]},#{log[:server_role]},#{log[:stream]},#{log[:level]},#{log[:message]}"
    end

    response(body)
  end
end
