# frozen_string_literal: true

# Generates OpenTelemetry Collector YAML configuration for shipping PostgreSQL
# logs to a Parseable backend (via OTLP HTTP) and optionally to user-configured
# syslog destinations (RFC 5424 over TLS).
#
# Produces a unified log schema across two sources:
#   filelog/pglog  — PostgreSQL JSON log files → stream: "postgres"
#   journald       — systemd journal units   → stream: "postgres" | "pgbouncer" | "upgrade"
#
# Unified fields emitted for every log record:
#   body             Log message text
#   severity_number  OTel native severity level (set via severity_parser)
#   severity_text    OTel native severity label
#   stream           Source category: postgres / pgbouncer / upgrade
#   instance         Ubid of the PostgresServer that produced this log
#   server_role      Role of the server: primary / standby
#
# pglog-only attributes (passed through from PostgreSQL JSON format):
#   pid, session_id, session_start, txid, vxid, backend_type,
#   dbname, user, remote_host, remote_port, query_id, detail,
#   state_code, line_num, ps
#
# RFC 5424 syslog header fields (for syslog exporters):
#   APP-NAME = resource_id
#   MSGID    = stream
#   SD-ID    = ubi@0, carrying instance, server_role, severity
class OtelLogConfig
  PARSEABLE_CA_CERT_PATH = "/etc/otelcol/certs/parseable-ca.crt"

  def initialize(resource_id:, instance:, server_role:, log_dir:,
    parseable_endpoint:, parseable_username:, parseable_password:,
    parseable_ca_bundle: nil, parseable_server_name: nil,
    log_destinations: [])
    @resource_id = resource_id
    @instance = instance
    @server_role = server_role
    @log_dir = log_dir
    @parseable_endpoint = parseable_endpoint
    @parseable_username = parseable_username
    @parseable_password = parseable_password
    @parseable_ca_bundle = parseable_ca_bundle
    @parseable_server_name = parseable_server_name
    @log_destinations = log_destinations
  end

  def use_parseable_tls?
    @parseable_ca_bundle && @parseable_endpoint.start_with?("https://")
  end

  def parseable_ca_cert_path
    PARSEABLE_CA_CERT_PATH
  end

  def syslog_ca_cert_path(index)
    "/etc/otelcol/certs/dest#{index}-ca.crt"
  end

  def to_config
    <<~YAML
      extensions:
        basicauth/parseable:
          client_auth:
            username: "#{@parseable_username}"
            password: "#{@parseable_password}"
        health_check:
          endpoint: 0.0.0.0:13133
        file_storage/state:
          directory: /var/lib/otelcol/state
          create_directory: true
          compaction:
            directory: /tmp/otelcol
            on_start: true
            on_rebound: true
            rebound_needed_threshold_mib: 1024
            rebound_trigger_threshold_mib: 100

      receivers:
        filelog/pglog:
          include:
            - "#{@log_dir}/postgresql-*.json"
          start_at: end
          storage: file_storage/state
          operators:
            - id: parse_json
              type: json_parser
              on_error: send
              timestamp:
                parse_from: attributes.timestamp
                layout: "2006-01-02 15:04:05.000 UTC"
                layout_type: gotime
              severity:
                parse_from: attributes.error_severity
                preset: none
                mapping:
                  fatal: [FATAL, PANIC]
                  error: ERROR
                  warn: WARNING
                  info3: NOTICE
                  info: [INFO, LOG]
                  debug: [DEBUG, DEBUG1, DEBUG2, DEBUG3, DEBUG4, DEBUG5]
            - type: move
              from: attributes.message
              to: body
            - type: remove
              field: attributes.error_severity
            - type: add
              field: attributes.stream
              value: postgres
            - type: add
              field: attributes.instance
              value: "#{@instance}"
            - type: add
              field: attributes.server_role
              value: "#{@server_role}"
            - type: remove
              field: attributes.timestamp
            - type: add
              field: attributes.app_name
              value: "#{@resource_id}"
            - type: add
              field: attributes.msg_id
              value: postgres

        journald:
          storage: file_storage/state
          operators:
            - id: filter_units
              type: router
              routes:
                - output: mark_postgres_stream
                  expr: 'body["_SYSTEMD_UNIT"] != nil && body["_SYSTEMD_UNIT"] startsWith "postgresql@"'
                - output: mark_pgbouncer_stream
                  expr: 'body["_SYSTEMD_UNIT"] != nil && body["_SYSTEMD_UNIT"] startsWith "pgbouncer@"'
                - output: mark_upgrade_stream
                  expr: 'body["_SYSTEMD_UNIT"] != nil && body["_SYSTEMD_UNIT"] startsWith "upgrade_postgres"'
            - id: mark_postgres_stream
              type: add
              field: attributes.stream
              value: postgres
              output: set_common_fields
            - id: mark_pgbouncer_stream
              type: add
              field: attributes.stream
              value: pgbouncer
              output: set_common_fields
            - id: mark_upgrade_stream
              type: add
              field: attributes.stream
              value: upgrade
              output: set_common_fields
            - id: set_common_fields
              type: add
              field: attributes.instance
              value: "#{@instance}"
            - type: add
              field: attributes.server_role
              value: "#{@server_role}"
            - type: add
              field: attributes.app_name
              value: "#{@resource_id}"
            - type: add
              field: attributes.msg_id
              value: journald
            - type: move
              from: body
              to: attributes.journald
            - type: move
              from: attributes.journald["MESSAGE"]
              to: body
            - type: flatten
              field: attributes.journald
            - type: move
              from: attributes["_PID"]
              to: attributes.pid
            - id: parse_journald_severity
              type: severity_parser
              parse_from: attributes["PRIORITY"]
              preset: none
              mapping:
                fatal: ["0", "1", "2"]
                error: "3"
                warn: "4"
                info3: "5"
                info: "6"
                debug: "7"
            - type: retain
              fields:
                - body
                - attributes.stream
                - attributes.instance
                - attributes.server_role
                - attributes.app_name
                - attributes.msg_id
                - attributes.pid

      processors:
        batch:

      exporters:
        otlphttp/parseable:
          endpoint: "#{@parseable_endpoint}"
          encoding: json
          headers:
            X-P-Stream: "#{@resource_id}"
            X-P-Log-Source: otel-logs
          auth:
            authenticator: basicauth/parseable
      #{indent(parseable_tls_yaml, 4)}
      #{indent(syslog_exporters_yaml, 4)}
      service:
        extensions: [basicauth/parseable, health_check, file_storage/state]
        pipelines:
          logs/pglog:
            receivers: [filelog/pglog]
            processors: [batch]
            exporters: [#{all_exporter_names.join(", ")}]
          logs/journal:
            receivers: [journald]
            processors: [batch]
            exporters: [#{all_exporter_names.join(", ")}]
    YAML
  end

  private

  def parseable_tls_yaml
    return "" unless use_parseable_tls?

    lines = ["tls:"]
    lines << "  ca_file: #{parseable_ca_cert_path}"
    if @parseable_server_name
      lines << "  server_name_override: #{@parseable_server_name}"
      lines << "  insecure_skip_verify: true"
    end
    lines.join("\n")
  end

  def syslog_exporters_yaml
    @log_destinations.each_with_index.map { |dest, i|
      syslog_exporter_yaml(dest, i)
    }.join("\n")
  end

  def syslog_exporter_yaml(dest, index)
    lines = []
    lines << "syslog/dest#{index}:"
    lines << "  endpoint: \"#{dest[:host]}\""
    lines << "  port: #{dest[:port]}"
    lines << "  network: tcp"
    lines << "  protocol: rfc5424"
    lines << "  tls:"
    lines << "    insecure: false"
    lines << "    ca_file: #{syslog_ca_cert_path(index)}" if dest[:ca_bundle]
    lines.join("\n")
  end

  def all_exporter_names
    names = ["otlphttp/parseable"]
    names + @log_destinations.each_with_index.map { |_, i| "syslog/dest#{i}" }
  end

  def indent(text, spaces)
    return "" if text.strip.empty?
    pad = " " * spaces
    text.chomp.lines.map { |l| (l == "\n") ? l : "#{pad}#{l}" }.join
  end
end
