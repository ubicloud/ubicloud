# frozen_string_literal: true

require "yaml"
require_relative "../lib/otel_log_config"

RSpec.describe OtelLogConfig do
  let(:instance) { "pg1abc2def3" }
  let(:server_role) { "primary" }
  let(:log_dir) { "/dat/17/data/pg_log" }
  let(:resource_name) { "my-pg-db" }
  let(:resource_id) { "pg9x8y7z6w" }
  let(:log_destinations) { [] }
  let(:config) { described_class.new(instance: instance, server_role: server_role, log_dir: log_dir, resource_name: resource_name, resource_id: resource_id, log_destinations: log_destinations) }
  let(:parsed) { YAML.safe_load(config.to_config, aliases: true) }

  describe "#to_config" do
    it "includes health_check and file_storage extensions" do
      expect(parsed["extensions"]).to have_key("health_check")
      expect(parsed["extensions"]).to have_key("file_storage/state")
    end

    it "configures the pglog filelog receiver with the correct log dir" do
      expect(parsed["receivers"]["filelog/pglog"]["include"]).to include("/dat/17/data/pg_log/postgresql-*.log")
    end

    it "tags pglog events with instance and server_role" do
      pglog_ops = parsed["receivers"]["filelog/pglog"]["operators"]
      expect(pglog_ops.select { |op| op["field"] == "attributes.instance" }.map { |op| op["value"] }).to all(eq("pg1abc2def3"))
      expect(pglog_ops.select { |op| op["field"] == "attributes.server_role" }.map { |op| op["value"] }).to all(eq("primary"))
    end

    it "sets hostname to the instance ubid in the pglog receiver" do
      pglog_ops = parsed["receivers"]["filelog/pglog"]["operators"]
      expect(pglog_ops).to include(include("field" => "attributes.hostname", "value" => "pg1abc2def3"))
    end

    it "removes error_severity after severity parsing" do
      pglog_ops = parsed["receivers"]["filelog/pglog"]["operators"]
      expect(pglog_ops).to include(include("type" => "remove", "field" => "attributes.error_severity"))
    end

    it "retains only the expected fields in the pglog receiver" do
      retain_op = parsed["receivers"]["filelog/pglog"]["operators"].find { |op| op["type"] == "retain" }
      expect(retain_op["fields"]).to include(
        "body", "attributes.message",
        "attributes.stream", "attributes.instance", "attributes.server_role", "attributes.hostname",
        "attributes.resource_name", "attributes.resource_id",
        "attributes.pid", "attributes.dbname", "attributes.user",
        "attributes.app_name", "attributes.remote_host", "attributes.remote_host_port",
      )
    end

    it "maps pglog severity levels without using non-standard info3" do
      severity_op = parsed["receivers"]["filelog/pglog"]["operators"].find { |op| op["type"] == "regex_parser" }
      mapping = severity_op["severity"]["mapping"]
      expect(mapping).not_to have_key("info3")
      expect(mapping["info"]).to include("NOTICE", "INFO", "LOG", "DETAIL", "HINT")
      expect(mapping["warn"]).to eq("WARNING")
      expect(mapping["fatal"]).to include("FATAL", "PANIC")
    end

    it "maps journald severity levels without using non-standard info3" do
      severity_op = parsed["receivers"]["journald"]["operators"].find { |op| op["type"] == "severity_parser" }
      mapping = severity_op["mapping"]
      expect(mapping).not_to have_key("info3")
      expect(Array(mapping["info"])).to include("5", "6")
    end

    it "falls back to copying body into attributes.message when the regex did not match" do
      pglog_ops = parsed["receivers"]["filelog/pglog"]["operators"]
      fallback_idx = pglog_ops.index { |op| op["type"] == "copy" && op["from"] == "body" && op["to"] == "attributes.message" }
      promote_idx = pglog_ops.index { |op| op["type"] == "copy" && op["from"] == "attributes.message" && op["to"] == "body" }
      expect(fallback_idx).not_to be_nil
      expect(pglog_ops[fallback_idx]["if"]).to eq("attributes.message == nil")
      expect(fallback_idx).to be < promote_idx
    end

    it "configures the journald receiver" do
      expect(parsed["receivers"]).to have_key("journald")
    end

    it "filters journal to postgres-related units" do
      routes = parsed["receivers"]["journald"]["operators"].find { |op| op["id"] == "filter_units" }["routes"]
      exprs = routes.map { |r| r["expr"] }
      expect(exprs).to include(a_string_including('startsWith "postgresql@"'))
      expect(exprs).to include(a_string_including('startsWith "pgbouncer@"'))
      expect(exprs).to include(a_string_including('startsWith "upgrade_postgres"'))
    end

    it "marks journal streams correctly" do
      op_ids = parsed["receivers"]["journald"]["operators"].filter_map { |op| op["id"] }
      expect(op_ids).to include("mark_postgres_stream", "mark_pgbouncer_stream", "mark_upgrade_stream")
    end

    it "includes a batch processor" do
      expect(parsed["processors"]).to have_key("batch")
    end

    it "includes a memory_limiter processor" do
      expect(parsed["processors"]["memory_limiter"]).to include("limit_mib", "spike_limit_mib")
    end

    it "lists health_check and file_storage in service extensions" do
      expect(parsed["service"]["extensions"]).to contain_exactly("health_check", "file_storage/state")
    end

    context "with no destinations" do
      let(:log_destinations) { [] }

      it "produces a nop exporter" do
        expect(parsed["exporters"]).to have_key("nop")
      end

      it "produces no transform processors" do
        expect(parsed["processors"].keys).not_to include(a_string_starting_with("transform/"))
      end

      it "produces noop pipelines for pglog and journal" do
        expect(parsed["service"]["pipelines"]).to have_key("logs/pglog/noop")
        expect(parsed["service"]["pipelines"]).to have_key("logs/journal/noop")
        expect(parsed["service"]["pipelines"]["logs/pglog/noop"]["exporters"]).to eq(["nop"])
      end
    end

    context "with one syslog destination and no options" do
      let(:log_destinations) do
        [{"type" => "syslog", "url" => "tcp://logs.example.com:6514", "options" => nil}]
      end

      it "creates a syslog exporter with the correct host and port" do
        exporter = parsed["exporters"]["syslog/dest0"]
        expect(exporter["endpoint"]).to eq("logs.example.com")
        expect(exporter["port"]).to eq(6514)
      end

      it "uses TCP with RFC 5424" do
        exporter = parsed["exporters"]["syslog/dest0"]
        expect(exporter["network"]).to eq("tcp")
        expect(exporter["protocol"]).to eq("rfc5424")
      end

      it "enables TLS" do
        expect(parsed["exporters"]["syslog/dest0"]["tls"]["insecure"]).to be false
      end

      it "creates pglog and journal pipelines for the destination" do
        expect(parsed["service"]["pipelines"]).to have_key("logs/pglog/dest0")
        expect(parsed["service"]["pipelines"]).to have_key("logs/journal/dest0")
      end

      it "creates a transform processor for the destination" do
        expect(parsed["processors"]).to have_key("transform/dest0")
      end

      it "includes proc_id, appname, priority and message formatting statements" do
        statements = parsed["processors"]["transform/dest0"]["log_statements"].flat_map { |s| s["statements"] }
        expect(statements).to include(a_string_including('log.attributes["proc_id"]'))
        expect(statements).to include(a_string_including('log.attributes["appname"]') & a_string_including("my-pg-db-"))
        expect(statements).to include(a_string_matching(/log\.attributes\["priority"\].*log\.severity_number/))
        expect(statements).to include(a_string_including("log.severity_text"))
      end

      it "prepends pglog context fields to attributes[message] for pglog entries" do
        statements = parsed["processors"]["transform/dest0"]["log_statements"].flat_map { |s| s["statements"] }
        expect(statements).to include(
          a_string_matching(/log\.attributes\["remote_host_port"\].*log\.attributes\["dbname"\].*log\.attributes\["user"\].*log\.attributes\["app_name"\].*log\.attributes\["remote_host"\]/) &
          a_string_including('where log.attributes["dbname"] != nil'),
        )
      end

      it "includes the transform processor in the pipeline" do
        pglog = parsed["service"]["pipelines"]["logs/pglog/dest0"]
        expect(pglog["processors"]).to eq(["memory_limiter", "transform/dest0", "batch"])
      end

      it "does not create a transform/enrich processor" do
        expect(parsed["processors"]).not_to have_key("transform/enrich")
      end
    end

    context "with syslog structured_data in options" do
      let(:log_destinations) do
        [{
          "type" => "syslog",
          "url" => "tcp://logs.example.com:6514",
          "options" => {"structured_data" => {"honeybadger@61642" => {"api_key" => "secret", "env" => "prod"}}},
        }]
      end

      it "creates a transform processor for the destination" do
        expect(parsed["processors"]).to have_key("transform/dest0")
      end

      it "emits structured_data set statements in the transform processor" do
        statements = parsed["processors"]["transform/dest0"]["log_statements"].flat_map { |s| s["statements"] }
        expect(statements).to include(a_string_including('log.attributes["structured_data"]["honeybadger@61642"]["api_key"], "secret"'))
        expect(statements).to include(a_string_including('log.attributes["structured_data"]["honeybadger@61642"]["env"], "prod"'))
      end

      it "includes the transform processor in the pipeline" do
        pglog = parsed["service"]["pipelines"]["logs/pglog/dest0"]
        expect(pglog["processors"]).to eq(["memory_limiter", "transform/dest0", "batch"])
      end
    end

    context "with syslog structured_data value containing double quotes" do
      let(:log_destinations) do
        [{"type" => "syslog", "url" => "tcp://logs.example.com:6514", "options" => {"structured_data" => {"sd@1" => {"key" => 'val"ue'}}}}]
      end

      it "escapes double quotes in structured_data values" do
        statements = parsed["processors"]["transform/dest0"]["log_statements"].flat_map { |s| s["statements"] }
        expect(statements).to include(a_string_including('["key"], "val\\"ue"'))
      end
    end

    context "with one otlp destination and no headers" do
      let(:log_destinations) do
        [{"type" => "otlp", "url" => "https://otlp.nr-data.net", "options" => nil}]
      end

      it "creates an otlphttp exporter with the correct endpoint" do
        exporter = parsed["exporters"]["otlp_http/dest0"]
        expect(exporter["endpoint"]).to eq("https://otlp.nr-data.net")
      end

      it "omits headers from the exporter when nil" do
        exporter = parsed["exporters"]["otlp_http/dest0"]
        expect(exporter).not_to have_key("headers")
      end

      it "configures retry_on_failure for the otlp exporter" do
        retry_cfg = parsed["exporters"]["otlp_http/dest0"]["retry_on_failure"]
        expect(retry_cfg).to include("enabled" => true, "initial_interval" => "5s", "max_interval" => "30s")
      end

      it "configures a persistent sending_queue backed by file_storage for the otlp exporter" do
        queue_cfg = parsed["exporters"]["otlp_http/dest0"]["sending_queue"]
        expect(queue_cfg).to include("storage" => "file_storage/state", "queue_size" => 1000)
      end

      it "creates pglog and journal pipelines for the destination" do
        expect(parsed["service"]["pipelines"]).to have_key("logs/pglog/dest0")
        expect(parsed["service"]["pipelines"]).to have_key("logs/journal/dest0")
      end

      it "includes only the batch processor in the pipeline" do
        pglog = parsed["service"]["pipelines"]["logs/pglog/dest0"]
        expect(pglog["processors"]).to eq(["memory_limiter", "batch"])
      end

      it "does not create a transform processor" do
        expect(parsed["processors"].keys).not_to include(a_string_starting_with("transform/"))
      end
    end

    context "with one otlp destination and headers" do
      let(:log_destinations) do
        [{"type" => "otlp", "url" => "https://otlp.nr-data.net", "options" => {"headers" => {"api-key" => "secret", "X-Custom" => "val"}}}]
      end

      it "includes the headers in the exporter config" do
        exporter = parsed["exporters"]["otlp_http/dest0"]
        expect(exporter["headers"]).to eq({"api-key" => "secret", "X-Custom" => "val"})
      end
    end

    context "with multiple syslog destinations" do
      let(:log_destinations) do
        [
          {"type" => "syslog", "url" => "tcp://logs1.example.com:6514", "options" => nil},
          {"type" => "syslog", "url" => "tcp://logs2.example.com:6515", "options" => nil},
        ]
      end

      it "creates a separate syslog exporter for each destination" do
        expect(parsed["exporters"]).to have_key("syslog/dest0")
        expect(parsed["exporters"]).to have_key("syslog/dest1")
      end

      it "uses the correct host and port for each destination" do
        expect(parsed["exporters"]["syslog/dest0"]["endpoint"]).to eq("logs1.example.com")
        expect(parsed["exporters"]["syslog/dest0"]["port"]).to eq(6514)
        expect(parsed["exporters"]["syslog/dest1"]["endpoint"]).to eq("logs2.example.com")
        expect(parsed["exporters"]["syslog/dest1"]["port"]).to eq(6515)
      end

      it "creates pglog and journal pipelines for each destination" do
        pipelines = parsed["service"]["pipelines"]
        expect(pipelines).to have_key("logs/pglog/dest0")
        expect(pipelines).to have_key("logs/pglog/dest1")
        expect(pipelines).to have_key("logs/journal/dest0")
        expect(pipelines).to have_key("logs/journal/dest1")
      end
    end

    context "with multiple otlp destinations" do
      let(:log_destinations) do
        [
          {"type" => "otlp", "url" => "https://otlp.nr-data.net", "options" => {"headers" => {"api-key" => "key1"}}},
          {"type" => "otlp", "url" => "https://otlp.intake.datadoghq.com", "options" => {"headers" => {"DD-API-KEY" => "key2"}}},
        ]
      end

      it "creates a separate otlphttp exporter for each destination" do
        expect(parsed["exporters"]).to have_key("otlp_http/dest0")
        expect(parsed["exporters"]).to have_key("otlp_http/dest1")
      end

      it "does not create any transform processors for otlp destinations" do
        expect(parsed["processors"].keys).not_to include(a_string_starting_with("transform/"))
      end
    end

    context "with mixed otlp and syslog destinations" do
      let(:log_destinations) do
        [
          {"type" => "otlp", "url" => "https://otlp.nr-data.net", "options" => {"headers" => {"api-key" => "key1"}}},
          {"type" => "syslog", "url" => "tcp://logs.example.com:6514", "options" => nil},
        ]
      end

      it "creates an otlphttp exporter for the otlp destination" do
        expect(parsed["exporters"]).to have_key("otlp_http/dest0")
      end

      it "creates a syslog exporter for the syslog destination" do
        expect(parsed["exporters"]).to have_key("syslog/dest1")
      end

      it "uses only batch for the otlp pipeline" do
        pglog = parsed["service"]["pipelines"]["logs/pglog/dest0"]
        expect(pglog["processors"]).to eq(["memory_limiter", "batch"])
        expect(pglog["exporters"]).to eq(["otlp_http/dest0"])
      end

      it "uses transform/dest1 for the syslog pipeline" do
        pglog = parsed["service"]["pipelines"]["logs/pglog/dest1"]
        expect(pglog["processors"]).to eq(["memory_limiter", "transform/dest1", "batch"])
        expect(pglog["exporters"]).to eq(["syslog/dest1"])
      end
    end

    context "with parseable destination (no CA bundle)" do
      let(:config) do
        described_class.new(
          instance: instance, server_role: server_role, log_dir: log_dir,
          resource_name: resource_name, resource_id: resource_id, log_destinations: [],
          parseable_endpoint: "https://parseable.example.com",
          parseable_username: "admin", parseable_password: "secret",
          parseable_ca_bundle: nil,
        )
      end

      it "adds basicauth/parseable extension" do
        expect(parsed["extensions"]).to have_key("basicauth/parseable")
        expect(parsed["extensions"]["basicauth/parseable"]["client_auth"]["username"]).to eq("admin")
        expect(parsed["extensions"]["basicauth/parseable"]["client_auth"]["password"]).to eq("secret")
      end

      it "includes basicauth/parseable in service extensions" do
        expect(parsed["service"]["extensions"]).to include("basicauth/parseable")
      end

      it "creates otlphttp/parseable exporter with json encoding" do
        exporter = parsed["exporters"]["otlp_http/parseable"]
        expect(exporter["endpoint"]).to eq("https://parseable.example.com")
        expect(exporter["encoding"]).to eq("json")
      end

      it "sets X-P-Stream and X-P-Log-Source headers" do
        headers = parsed["exporters"]["otlp_http/parseable"]["headers"]
        expect(headers["X-P-Stream"]).to eq(resource_id)
        expect(headers["X-P-Log-Source"]).to eq("otel-logs")
      end

      it "creates parseable pipelines for pglog and journald" do
        expect(parsed["service"]["pipelines"]).to have_key("logs/pglog/parseable")
        expect(parsed["service"]["pipelines"]).to have_key("logs/journal/parseable")
      end

      it "uses memory_limiter and batch processors in parseable pipelines" do
        pglog = parsed["service"]["pipelines"]["logs/pglog/parseable"]
        expect(pglog["processors"]).to eq(["memory_limiter", "transform/parseable", "batch"])
        expect(pglog["exporters"]).to eq(["otlp_http/parseable"])
      end

      it "uses UUIDv7 for sortable Parseable log ids" do
        statements = parsed["processors"]["transform/parseable"]["log_statements"].first["statements"]
        expect(statements).to eq(["set(log.attributes[\"log_id\"], UUIDv7())"])
      end

      it "does not create a transform/enrich processor" do
        expect(parsed["processors"]).not_to have_key("transform/enrich")
      end

      it "does not produce a nop exporter" do
        expect(parsed["exporters"]).not_to have_key("nop")
      end
    end

    context "with parseable destination and CA bundle" do
      let(:config) do
        described_class.new(
          instance: instance, server_role: server_role, log_dir: log_dir,
          resource_name: resource_name, resource_id: resource_id, log_destinations: [],
          parseable_endpoint: "https://parseable.internal",
          parseable_username: "admin", parseable_password: "secret",
          parseable_ca_bundle: "-----BEGIN CERTIFICATE-----\n...",
        )
      end

      it "uses ca_file for TLS when CA bundle is provided" do
        expect(parsed["exporters"]["otlp_http/parseable"]["tls"]["ca_file"]).to eq(OtelLogConfig::PARSEABLE_CA_CERT_PATH)
      end

      it "does not use insecure_skip_verify" do
        expect(parsed["exporters"]["otlp_http/parseable"]["tls"]).not_to have_key("insecure_skip_verify")
      end
    end

    context "with parseable destination and an otlp user destination" do
      let(:config) do
        described_class.new(
          instance: instance, server_role: server_role, log_dir: log_dir,
          resource_name: resource_name, resource_id: resource_id,
          log_destinations: [{"type" => "otlp", "url" => "https://otlp.example.com", "options" => {"headers" => {"api-key" => "k"}}}],
          parseable_endpoint: "https://parseable.example.com",
          parseable_username: "admin", parseable_password: "secret",
          parseable_ca_bundle: nil,
        )
      end

      it "creates both parseable and user destination pipelines" do
        pipelines = parsed["service"]["pipelines"]
        expect(pipelines).to have_key("logs/pglog/parseable")
        expect(pipelines).to have_key("logs/pglog/dest0")
      end

      it "does not create a transform/enrich processor for otlp user destinations" do
        expect(parsed["processors"]).not_to have_key("transform/enrich")
        expect(parsed["processors"].keys).not_to include("transform/dest0")
      end
    end
  end
end
