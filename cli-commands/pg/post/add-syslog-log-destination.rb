# frozen_string_literal: true

UbiCli.on("pg").run_on("add-syslog-log-destination") do
  desc "Add a syslog (RFC 5424 over TLS) log destination to a PostgreSQL database"

  banner "ubi pg (location/pg-name | pg-id) add-syslog-log-destination name host [port] [sd-id/key=value [...]]"

  args(2..)

  run do |args, _, cmd|
    name, host, *rest = args
    port = 6514
    if rest.first&.match?(/\A\d+\z/)
      port = Integer(rest.shift)
    end
    structured_data = structured_data_args_to_hash(rest, cmd) || {}
    ld = sdk_object.add_syslog_log_destination(name:, host:, port:, structured_data:)
    response("Log destination added to PostgreSQL database.\n  id: #{ld[:id]}\n")
  end
end
