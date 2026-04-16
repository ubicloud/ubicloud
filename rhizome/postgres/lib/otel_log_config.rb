# frozen_string_literal: true

require "yaml"
require "uri"

# Generates OpenTelemetry Collector YAML configuration for shipping PostgreSQL
# logs to one or more destinations.
#
# Supports two destination types:
#   otlp   — OTLP HTTP endpoint (https://...). Optional per-destination headers,
#            TLS CA bundle, and encoding (e.g. "json"). Every record is stamped
#            with a sortable UUIDv7 in attributes["log_id"].
#   syslog — RFC 5424 over TLS (tcp://host:port), authenticated via structured data.
#
# Produces a unified log schema across two sources:
#   filelog/pglog  — PostgreSQL stderr log files (parsed via log_line_prefix regex) → stream: "postgres"
#   journald       — systemd journal units   → stream: "postgres" | "pgbouncer" | "upgrade"
#
# Unified fields emitted for every log record:
#   body             Log message text
#   severity_number  OTel native severity level (set via severity_parser)
#   severity_text    OTel native severity label
#   stream           Source category: postgres / pgbouncer / upgrade
#   instance         Ubid of the PostgresServer that produced this log
#   server_role      Role of the server: primary / standby
#   hostname         Postgres server ubid (used by syslog exporter)
#
# pglog-only attributes (parsed from log_line_prefix format):
#   pid, dbname, user, app_name, remote_host_port, remote_host
#
# RFC 5424 syslog header fields (mapped from log attributes by the syslog exporter):
#   HOSTNAME = postgres server ubid  (attributes["hostname"])
#   APP-NAME = log stream: postgres / pgbouncer / upgrade  (attributes["appname"])
#   PROC-ID  = process id  (attributes["proc_id"])
#   MSG      = message text  (attributes["message"])
class OtelLogConfig
  def self.dest_ca_file_path(i)
    "/etc/otelcol-contrib/dest#{i}-ca.crt"
  end

  def initialize(instance:, server_role:, log_dir:, resource_name:, resource_id:, log_destinations:)
    @instance = instance
    @server_role = server_role
    @log_dir = log_dir
    @resource_name = resource_name
    @resource_id = resource_id
    @log_destinations = log_destinations
  end

  def to_config
    YAML.dump(config_hash)
  end

  private

  def config_hash
    {
      "extensions" => extensions_hash,
      "receivers" => receivers_hash,
      "processors" => processors_hash,
      "exporters" => exporters_hash,
      "service" => service_hash,
    }
  end

  def extensions_hash
    {
      "health_check" => {"endpoint" => "0.0.0.0:13133"},
      "file_storage/state" => {
        "directory" => "/var/lib/otelcol-contrib/state",
        "create_directory" => true,
        "compaction" => {
          "directory" => "/tmp/otelcol",
          "on_start" => true,
          "on_rebound" => true,
          "rebound_needed_threshold_mib" => 1024,
          "rebound_trigger_threshold_mib" => 100,
        },
      },
    }
  end

  def receivers_hash
    {
      "filelog/pglog" => filelog_receiver_hash,
      "journald" => journald_receiver_hash,
    }
  end

  def filelog_receiver_hash
    {
      "include" => ["#{@log_dir}/postgresql-*.log"],
      "start_at" => "end",
      "storage" => "file_storage/state",
      "operators" => [
        {
          "type" => "regex_parser",
          "regex" => '^(?P<timestamp>\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3} \w+) \[(?P<pid>\d+):\d+\] \([^,]*,[^)]*\): host=(?P<remote_host_port>[^,]*),db=(?P<dbname>[^,]*),user=(?P<user>[^,]*),app=(?P<app_name>.*?),client=(?P<remote_host>\S*) (?P<error_severity>[A-Z0-9]+):\s+(?P<message>.*)',
          "on_error" => "send_quiet",
          "timestamp" => {
            "parse_from" => "attributes.timestamp",
            "layout" => "2006-01-02 15:04:05.000 MST",
            "layout_type" => "gotime",
          },
          "severity" => {
            "parse_from" => "attributes.error_severity",
            "preset" => "none",
            "mapping" => {
              "fatal" => ["FATAL", "PANIC"],
              "error" => "ERROR",
              "warn" => "WARNING",
              "info3" => "NOTICE",
              "info" => ["INFO", "LOG"],
              "debug" => ["DEBUG", "DEBUG1", "DEBUG2", "DEBUG3", "DEBUG4", "DEBUG5"],
            },
          },
        },
        {"type" => "copy", "from" => "body", "to" => "attributes.message", "if" => "attributes.message == nil"},
        {"type" => "copy", "from" => "attributes.message", "to" => "body"},
        {"type" => "remove", "field" => "attributes.error_severity", "if" => "attributes.error_severity != nil"},
        {"type" => "add", "field" => "attributes.stream", "value" => "postgres"},
        {"type" => "add", "field" => "attributes.instance", "value" => @instance},
        {"type" => "add", "field" => "attributes.server_role", "value" => @server_role},
        {"type" => "add", "field" => "attributes.hostname", "value" => @instance},
        {"type" => "add", "field" => "attributes.resource_name", "value" => @resource_name},
        {"type" => "add", "field" => "attributes.resource_id", "value" => @resource_id},
        {"type" => "remove", "field" => "attributes.timestamp", "if" => "attributes.timestamp != nil"},
      ],
    }
  end

  def journald_receiver_hash
    {
      "storage" => "file_storage/state",
      "operators" => [
        {
          "id" => "filter_units",
          "type" => "router",
          "routes" => [
            {"output" => "mark_postgres_stream", "expr" => 'body["_SYSTEMD_UNIT"] != nil && body["_SYSTEMD_UNIT"] startsWith "postgresql@"'},
            {"output" => "mark_pgbouncer_stream", "expr" => 'body["_SYSTEMD_UNIT"] != nil && body["_SYSTEMD_UNIT"] startsWith "pgbouncer@"'},
            {"output" => "mark_upgrade_stream", "expr" => 'body["_SYSTEMD_UNIT"] != nil && body["_SYSTEMD_UNIT"] startsWith "upgrade_postgres"'},
          ],
        },
        {"id" => "mark_postgres_stream", "type" => "add", "field" => "attributes.stream", "value" => "postgres", "output" => "set_common_fields"},
        {"id" => "mark_pgbouncer_stream", "type" => "add", "field" => "attributes.stream", "value" => "pgbouncer", "output" => "set_common_fields"},
        {"id" => "mark_upgrade_stream", "type" => "add", "field" => "attributes.stream", "value" => "upgrade", "output" => "set_common_fields"},
        {"id" => "set_common_fields", "type" => "add", "field" => "attributes.instance", "value" => @instance},
        {"type" => "add", "field" => "attributes.server_role", "value" => @server_role},
        {"type" => "add", "field" => "attributes.hostname", "value" => @instance},
        {"type" => "add", "field" => "attributes.resource_name", "value" => @resource_name},
        {"type" => "add", "field" => "attributes.resource_id", "value" => @resource_id},
        {"type" => "move", "from" => "body", "to" => "attributes.journald"},
        {"type" => "copy", "from" => 'attributes.journald["MESSAGE"]', "to" => "attributes.message"},
        {"type" => "move", "from" => 'attributes.journald["MESSAGE"]', "to" => "body"},
        {"type" => "flatten", "field" => "attributes.journald"},
        {"type" => "move", "from" => 'attributes["_PID"]', "to" => "attributes.pid"},
        {
          "type" => "severity_parser",
          "parse_from" => 'attributes["PRIORITY"]',
          "preset" => "none",
          "mapping" => {
            "fatal" => ["0", "1", "2"],
            "error" => "3",
            "warn" => "4",
            "info3" => "5",
            "info" => "6",
            "debug" => "7",
          },
        },
        {
          "type" => "retain",
          "fields" => [
            "body",
            "attributes.message",
            "attributes.stream",
            "attributes.instance",
            "attributes.server_role",
            "attributes.hostname",
            "attributes.resource_name",
            "attributes.resource_id",
            "attributes.pid",
          ],
        },
      ],
    }
  end

  def processors_hash
    hash = {
      "memory_limiter" => {
        "check_interval" => "1s",
        "limit_mib" => 128,
        "spike_limit_mib" => 32,
      },
      "batch" => nil,
    }

    @log_destinations.each_with_index do |dest, i|
      statements = case dest["type"]
      when "otlp"
        ['set(log.attributes["log_id"], UUIDv7())']
      when "syslog"
        syslog_transform_statements(dest)
      end
      hash["transform/dest#{i}"] = {
        "log_statements" => [{"context" => "log", "statements" => statements}],
      }
    end

    hash
  end

  def syslog_transform_statements(dest)
    statements = [
      "set(log.attributes[\"proc_id\"], log.attributes[\"pid\"]) where log.attributes[\"pid\"] != nil",
      "set(log.attributes[\"appname\"], Concat([\"#{ottl_escape(@resource_name)}-\", log.attributes[\"stream\"]], \"\"))",
      "set(log.attributes[\"priority\"], 135) where log.severity_number >= 1",
      "set(log.attributes[\"priority\"], 134) where log.severity_number >= 9",
      "set(log.attributes[\"priority\"], 133) where log.severity_number >= 11",
      "set(log.attributes[\"priority\"], 132) where log.severity_number >= 13",
      "set(log.attributes[\"priority\"], 131) where log.severity_number >= 17",
      "set(log.attributes[\"priority\"], 130) where log.severity_number >= 21",
      "set(log.attributes[\"message\"], Concat([\"host=\", log.attributes[\"remote_host_port\"], \",db=\", log.attributes[\"dbname\"], \",user=\", log.attributes[\"user\"], \",app=\", log.attributes[\"app_name\"], \",client=\", log.attributes[\"remote_host\"], \" \", log.attributes[\"message\"]], \"\")) where log.attributes[\"dbname\"] != nil",
      "set(log.attributes[\"message\"], Concat([log.severity_text, \":  \", log.attributes[\"message\"]], \"\")) where IsMatch(log.severity_text, \"^[A-Z]\")",
    ]
    ((dest["options"] || {})["structured_data"] || {}).each do |sd_id, params|
      params.each do |key, value|
        statements << "set(log.attributes[\"structured_data\"][\"#{ottl_escape(sd_id)}\"][\"#{ottl_escape(key)}\"], \"#{ottl_escape(value)}\")"
      end
    end
    statements
  end

  def exporters_hash
    hash = {}

    @log_destinations.each_with_index do |dest, i|
      if dest["type"] == "otlp"
        opts = dest["options"] || {}
        cfg = {
          "endpoint" => dest["url"],
          "retry_on_failure" => {
            "enabled" => true,
            "initial_interval" => "5s",
            "max_interval" => "30s",
            "max_elapsed_time" => "300s",
          },
          "sending_queue" => {
            "storage" => "file_storage/state",
            "queue_size" => 1000,
          },
        }
        cfg["headers"] = opts["headers"] if opts["headers"]
        cfg["encoding"] = opts["encoding"] if opts["encoding"]
        cfg["tls"] = {"ca_file" => self.class.dest_ca_file_path(i)} if opts["ca_bundle"]
        hash["otlp_http/dest#{i}"] = cfg
      else
        uri = URI.parse(dest["url"])
        hash["syslog/dest#{i}"] = {
          "endpoint" => uri.host,
          "port" => uri.port,
          "network" => "tcp",
          "protocol" => "rfc5424",
          "tls" => {"insecure" => false},
        }
      end
    end

    hash["nop"] = nil if hash.empty?
    hash
  end

  def service_hash
    {
      "extensions" => ["health_check", "file_storage/state"],
      "telemetry" => {
        "logs" => {"level" => "warn"},
        "metrics" => {
          "level" => "basic",
          "readers" => [{"pull" => {"exporter" => {"prometheus" => {"host" => "127.0.0.1", "port" => 8888}}}}],
        },
      },
      "pipelines" => pipelines_hash,
    }
  end

  def pipelines_hash
    if @log_destinations.empty?
      return {
        "logs/pglog/noop" => {"receivers" => ["filelog/pglog"], "processors" => ["memory_limiter", "batch"], "exporters" => ["nop"]},
        "logs/journal/noop" => {"receivers" => ["journald"], "processors" => ["memory_limiter", "batch"], "exporters" => ["nop"]},
      }
    end

    pipelines = {}
    @log_destinations.each_with_index do |dest, i|
      exporter = (dest["type"] == "otlp") ? "otlp_http/dest#{i}" : "syslog/dest#{i}"
      processors = ["memory_limiter", "transform/dest#{i}", "batch"]
      pipelines["logs/pglog/dest#{i}"] = {"receivers" => ["filelog/pglog"], "processors" => processors, "exporters" => [exporter]}
      pipelines["logs/journal/dest#{i}"] = {"receivers" => ["journald"], "processors" => processors, "exporters" => [exporter]}
    end
    pipelines
  end

  def ottl_escape(value)
    value.to_s.gsub("\\", "\\\\").gsub('"', '\\"')
  end
end
