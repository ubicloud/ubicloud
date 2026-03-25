# frozen_string_literal: true

# Generates Vector TOML configuration for shipping PostgreSQL logs to Parseable.
#
# Produces a unified log schema across two sources:
#   pglog  — PostgreSQL JSON log files → stream: "postgres"
#   journal — systemd journal units   → stream: "postgres" | "pgbouncer" | "upgrade"
#
# Unified fields emitted for every event:
#   ts        ISO-8601 timestamp
#   stream    Source category: postgres / pgbouncer / upgrade
#   message   Log message text
#   severity  Normalised severity: DEBUG / INFO / NOTICE / WARNING / ERROR / CRITICAL / LOG
#
# pglog-only fields (passed through from PostgreSQL JSON format):
#   pid, session_id, session_start, txid, vxid, backend_type,
#   dbname, user, remote_host, remote_port, query_id, detail,
#   state_code, line_num, ps
#
# Journal-only fields:
#   unit      Systemd unit name (e.g. "pgbouncer@50001.service")
class VectorLogConfig
  PGLOG_TRANSFORM = <<~VRL.freeze
    # Parse JSON from the log file line
    . = parse_json!(.message)

    # Normalise timestamp
    .ts = del(.timestamp)

    # Normalise severity
    .severity = del(.error_severity)

    # Tag source
    .stream = "postgres"
  VRL

  JOURNAL_FILTER_CONDITION = <<~VRL.freeze
    unit = string(._SYSTEMD_UNIT) ?? ""
    starts_with(unit, "postgresql@") || starts_with(unit, "pgbouncer@") || starts_with(unit, "upgrade_postgres")
  VRL

  # Maps journald PRIORITY (0-7) to a text severity matching PostgreSQL conventions.
  JOURNAL_TRANSFORM = <<~VRL.freeze
    unit = string(._SYSTEMD_UNIT) ?? ""

    # Derive stream from unit name
    stream = if starts_with(unit, "postgresql@") {
      "postgres"
    } else if starts_with(unit, "pgbouncer@") {
      "pgbouncer"
    } else {
      "upgrade"
    }

    # Map syslog PRIORITY to severity text
    priority = to_int(string(.PRIORITY) ?? "6") ?? 6
    severity = if priority <= 2 {
      "CRITICAL"
    } else if priority == 3 {
      "ERROR"
    } else if priority == 4 {
      "WARNING"
    } else if priority == 5 {
      "NOTICE"
    } else {
      "INFO"
    }

    # Reconstruct event with only the fields we want
    . = {
      "ts": .timestamp,
      "stream": stream,
      "unit": unit,
      "message": string(.message) ?? "",
      "severity": severity
    }
  VRL

  def initialize(resource_id:, log_dir:, parseable_endpoint:, parseable_username:,
    parseable_password:, parseable_ca_bundle: nil, parseable_server_name: nil)
    @resource_id = resource_id
    @log_dir = log_dir
    @parseable_endpoint = parseable_endpoint
    @parseable_username = parseable_username
    @parseable_password = parseable_password
    @parseable_ca_bundle = parseable_ca_bundle
    @parseable_server_name = parseable_server_name
  end

  def use_tls?
    @parseable_ca_bundle && @parseable_endpoint.start_with?("https://")
  end

  def ca_cert_path
    "/etc/vector/certs/parseable-ca.crt"
  end

  def to_toml
    <<~TOML
      data_dir = "/var/lib/vector"

      [sources.pglog]
      type = "file"
      include = ["#{@log_dir}/postgresql-*.json"]

      [transforms.parse_pglog]
      type = "remap"
      inputs = ["pglog"]
      source = '''
      #{indent(PGLOG_TRANSFORM, 6)}
      '''

      [sources.journal]
      type = "journald"

      [transforms.filter_journal]
      type = "filter"
      inputs = ["journal"]
      condition = '''
      #{indent(JOURNAL_FILTER_CONDITION, 6)}
      '''

      [transforms.format_journal]
      type = "remap"
      inputs = ["filter_journal"]
      source = '''
      #{indent(JOURNAL_TRANSFORM, 6)}
      '''

      [sinks.parseable]
      type = "http"
      inputs = ["parse_pglog", "format_journal"]
      uri = "#{@parseable_endpoint}/api/v1/logstream/#{@resource_id}"
      method = "post"
      encoding.codec = "json"

      [sinks.parseable.batch]
      max_events = 200
      timeout_secs = 10

      [sinks.parseable.auth]
      strategy = "basic"
      user = "#{@parseable_username}"
      password = "#{@parseable_password}"

      #{tls_section}
    TOML
  end

  private

  def tls_section
    return "" unless use_tls?

    lines = ["[sinks.parseable.tls]", "ca_file = \"#{ca_cert_path}\""]
    if @parseable_server_name
      lines << "server_name = \"#{@parseable_server_name}\""
      lines << "verify_hostname = false"
    end
    lines.join("\n")
  end

  def indent(text, spaces)
    pad = " " * spaces
    text.chomp.lines.map { |l| l == "\n" ? l : "#{pad}#{l}" }.join
  end
end
