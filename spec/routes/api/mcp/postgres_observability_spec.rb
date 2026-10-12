# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe Clover, "mcp postgres observability tools" do
  let(:ref) { "eu-central-h1/test-pg" }

  before do
    expect(Config).to receive(:postgres_service_project_id).and_return(@project.id).at_least(:once)
    @pg = Prog::Postgres::PostgresResourceNexus.assemble(
      project_id: @project.id,
      location_id: Location::HETZNER_FSN1_ID,
      name: "test-pg",
      target_vm_size: "standard-2",
      target_storage_size_gib: 64,
    ).subject
  end

  %w[get_postgres_metrics get_postgres_logs].each do |tool|
    describe "#{tool} references and permissions" do
      it "returns Forbidden by name when the token lacks Postgres:view" do
        restrict_pat_to("Project:view")
        expect(mcp_tool_error(tool, ref:)).to eq "Forbidden: Sorry, you don't have permission to continue with this request."
      end

      it "returns ResourceNotFound by id when the token lacks Postgres:view" do
        restrict_pat_to("Project:view")
        expect(mcp_tool_error(tool, ref: @pg.ubid)).to start_with "ResourceNotFound: "
      end

      it "rejects a malformed ref" do
        expect(mcp_tool_error(tool, ref: "foo")).to eq "InvalidRequest: ref must be location/name or a pg... id"
      end

      it "rejects a ref that would end the path early" do
        expect(mcp_tool_error(tool, ref: "eu-central-h1/test-pg?")).to eq "InvalidRequest: ref must be location/name or a pg... id"
      end

      it "returns ResourceNotFound for an unknown name" do
        expect(mcp_tool_error(tool, ref: "eu-central-h1/nope")).to start_with "ResourceNotFound: "
      end

      it "returns InvalidLocation for an unknown location" do
        expect(mcp_tool_error(tool, ref: "nowhere/test-pg")).to start_with "InvalidLocation: "
      end
    end
  end

  describe "get_postgres_metrics" do
    it "returns NotFound when metrics are not configured" do
      expect(mcp_tool_error("get_postgres_metrics", ref:)).to eq "NotFound: Metrics are not configured for this instance"
    end

    describe "with a metrics backend" do
      let(:tsdb_client) { instance_double(VictoriaMetrics::Client) }

      before do
        expect(Config).to receive(:victoria_metrics_endpoint_override).and_return("http://vm.test:8428").at_least(:once)
        expect(VictoriaMetrics::Client).to receive(:new).with(endpoint: "http://vm.test:8428").and_return(tsdb_client)
      end

      def expect_queries(count, values: [[1619712000, "10.5"], [1619715600, "12.3"]])
        queries = []
        expect(tsdb_client).to receive(:query_range).exactly(count).times do |query:, start_ts:, end_ts:|
          queries << [query, start_ts, end_ts]
          [{"values" => values, "labels" => {"instance" => "i"}}]
        end
        queries
      end

      def cpu_query
        Metrics::POSTGRES_METRICS[:cpu_usage].series.first.query.gsub("$ubicloud_resource_id", @pg.ubid)
      end

      it "summarizes every metric per series when the client sends Accept */*" do
        queries = expect_queries(Metrics::POSTGRES_METRICS.values.sum { it.series.count })

        result = mcp("tools/call", {name: "get_postgres_metrics", arguments: {ref:}}, env: {"HTTP_ACCEPT" => "*/*"}).fetch("result")
        expect(result["isError"]).to be false
        data = result["structuredContent"]
        expect(data["window"]).to eq({"start" => nil, "end" => nil})
        expect(data["metrics"].map { it["key"] }).to eq Metrics::POSTGRES_METRICS.keys.map(&:to_s)
        expect(data["metrics"].map(&:keys)).to all(eq %w[key name unit series])
        expect(data["metrics"].first).to eq({
          "key" => "cpu_usage",
          "name" => "CPU Usage",
          "unit" => "%",
          "series" => [{"labels" => {"instance" => "i"}, "samples" => 2, "min" => 10.5, "max" => 12.3, "avg" => 11.4, "last" => 12.3}],
        })
        expect(data["metrics"][1]["series"].map { it["labels"] }).to eq [
          {"instance" => "i", "name" => "1 minute"},
          {"instance" => "i", "name" => "5 minutes"},
          {"instance" => "i", "name" => "15 minutes"},
        ]
        expect(data["metrics"].flat_map { it["series"] }.map(&:keys)).to all(eq %w[labels samples min max avg last])

        expect(queries.first.first).to eq cpu_query
        expect(queries.map(&:first)).to all(include("ubicloud_resource_id=\"#{@pg.ubid}\""))
        expect(queries.map { it[2] - it[1] }).to all(be_between(1800, 1801))
      end

      it "returns one metric with points for an explicit window and an id ref" do
        now = Time.now.utc
        start = (now - 3600).iso8601
        finish = now.iso8601
        queries = expect_queries(1)

        expect(mcp_tool_data("get_postgres_metrics", ref: @pg.ubid, key: "cpu_usage", start:, end: finish, points: true)).to eq({
          "window" => {"start" => start, "end" => finish},
          "metrics" => [{
            "key" => "cpu_usage",
            "name" => "CPU Usage",
            "unit" => "%",
            "series" => [{
              "labels" => {"instance" => "i"},
              "samples" => 2,
              "min" => 10.5,
              "max" => 12.3,
              "avg" => 11.4,
              "last" => 12.3,
              "values" => [[1619712000, 10.5], [1619715600, 12.3]],
            }],
          }],
        })
        expect(queries).to eq [[cpu_query, (now - 3600).to_i, now.to_i]]
      end

      it "downsamples a long series to 24 buckets of mean values" do
        expect_queries(1, values: Array.new(30) { [1619712000 + 60 * it, it.to_s] })

        series = mcp_tool_data("get_postgres_metrics", ref:, key: "deadlocks", points: true).dig("metrics", 0, "series", 0)
        expect(series.except("values")).to eq({"labels" => {"instance" => "i"}, "samples" => 30, "min" => 0, "max" => 29, "avg" => 14.5, "last" => 29})
        expect(series["values"].size).to eq 24
        expect(series["values"].first(2)).to eq [[1619712000, 0.5], [1619712120, 2]]
        expect(series["values"].last).to eq [1619713740, 29]
      end

      it "summarizes only the finite samples" do
        expect_queries(1, values: [[1619712000, "NaN"], [1619712060, "10.5"], [1619712120, "+Inf"], [1619712240, "12.3"], [1619712300, "-Inf"]])

        series = mcp_tool_data("get_postgres_metrics", ref:, key: "cpu_usage", points: true).dig("metrics", 0, "series", 0)
        expect(series).to eq({"labels" => {"instance" => "i"}, "samples" => 2, "min" => 10.5, "max" => 12.3, "avg" => 11.4, "last" => 12.3, "values" => [[1619712060, 10.5], [1619712240, 12.3]]})
      end

      it "reports only the sample count of a series without finite samples" do
        expect_queries(1, values: [[1619712000, "NaN"], [1619712060, "NaN"]])

        series = mcp_tool_data("get_postgres_metrics", ref:, key: "cpu_usage", points: true).dig("metrics", 0, "series", 0)
        expect(series).to eq({"labels" => {"instance" => "i"}, "samples" => 0})
      end

      it "works with a token restricted to Postgres:view" do
        restrict_pat_to("Postgres:view")
        expect_queries(1)
        expect(mcp_tool_data("get_postgres_metrics", ref:, key: "cpu_usage").dig("metrics", 0, "key")).to eq "cpu_usage"
      end

      it "passes API validation errors through" do
        now = Time.now.utc
        expect(mcp_tool_error("get_postgres_metrics", ref:, start: now.iso8601, end: (now - 60).iso8601)).to eq "InvalidRequest: End timestamp must be greater than start timestamp"
      end
    end
  end

  describe "get_postgres_logs" do
    it "returns NotFound when log aggregation is not enabled" do
      expect(mcp_tool_error("get_postgres_logs", ref:)).to eq "NotFound: Log aggregation is not enabled for this instance"
    end

    it "passes API validation errors through" do
      now = Time.now.utc
      expect(mcp_tool_error("get_postgres_logs", ref:, start: (now - 25 * 3600).iso8601, end: now.iso8601)).to eq "InvalidRequest: Maximum time range for log queries is 24 hours"
    end

    it "rejects a malformed cursor before calling the API" do
      log_id = "0196a9f7-0000-7000-8000-000000000002"
      ["foo", log_id.upcase, "#{log_id}\nx"].each do |cursor|
        expect(mcp_tool_error("get_postgres_logs", ref:, cursor:)).to eq "InvalidRequest: cursor must be the next_cursor of a previous result"
      end
    end

    describe "with log aggregation" do
      let(:parseable_client) { instance_double(Parseable::Client) }
      let(:server_ubid) { @pg.representative_server.ubid }

      def create_parseable(project_id, name)
        resource = ParseableResource.create(project_id:, location_id: Location::HETZNER_FSN1_ID, name:, admin_user: "admin", admin_password: "#{name}-password", blob_storage_access_key: "access-key", blob_storage_secret_key: "secret-key", target_vm_size: "standard-2", target_storage_size_gib: 100)
        ParseableServer.create(parseable_resource_id: resource.id, vm_id: create_vm(project_id:, name: "#{name}-vm").id)
      end

      before do
        create_parseable(Project.create(name: "other").id, "other-parseable")
        create_parseable(@project.id, "test-parseable")
        expect(Parseable::Client).to receive(:new).with(endpoint: "https://test-parseable.#{Config.parseable_host_name}:8000", ssl_ca_data: nil, username: "admin", password: "test-parseable-password").and_return(parseable_client).at_least(:once)
      end

      def expected_sql(limit: 51, where: nil)
        cols = '"log_id", "time_unix_nano", "stream", "severity_text", "body", "instance", "server_role", "remote_host_port", "dbname", "pid", "user"'
        condition = where ? "(\"log_id\" IS NOT NULL) AND #{where}" : '"log_id" IS NOT NULL'
        "SELECT #{cols} FROM \"#{@pg.ubid}\" WHERE (#{condition}) ORDER BY \"log_id\" DESC LIMIT #{limit}"
      end

      def row(n, body, **context)
        {"log_id" => "0196a9f7-0000-7000-8000-00000000000#{n}", "time_unix_nano" => "2026-01-01T00:00:0#{n}", "stream" => "postgres", "severity_text" => "INFO", "body" => body, "instance" => server_ubid, "server_role" => "primary", **context}
      end

      def entry(n, message)
        {"timestamp" => "2026-01-01T00:00:0#{n}Z", "stream_name" => "postgres", "severity_level" => "INFO", "message" => message, "server_ubid" => server_ubid, "server_role" => "primary"}
      end

      it "returns log lines oldest first" do
        rows = [row(2, "connection received", "dbname" => "app", "pid" => "42"), row(1, "database started")]
        expect(parseable_client).to receive(:query).with(expected_sql, start_time: String, end_time: String).and_return(rows)

        expect(mcp_tool_data("get_postgres_logs", ref:)).to eq({
          "logs" => [
            entry(1, "database started"),
            entry(2, "connection received").merge("context" => {"dbname" => "app", "pid" => "42"}),
          ],
          "next_cursor" => nil,
        })
      end

      it "passes the window and filters to the query" do
        now = Time.now.utc
        start = (now - 3600).iso8601
        finish = now.iso8601
        where = "(\"stream\" = 'pgbouncer') AND (\"server_role\" = 'standby') AND (\"severity_text\" = 'ERROR') AND (\"message\" LIKE '%timeout%')"
        expect(parseable_client).to receive(:query).with(expected_sql(where:), start_time: start, end_time: finish).and_return([])

        expect(mcp_tool_data("get_postgres_logs", ref: @pg.ubid, start:, end: finish, stream_name: "pgbouncer", server_role: "standby", severity_level: "ERROR", query_pattern: "timeout")).to eq({"logs" => [], "next_cursor" => nil})
      end

      it "pages with limit and cursor" do
        expect(parseable_client).to receive(:query).with(expected_sql(limit: 3), start_time: String, end_time: String).and_return([row(3, "third"), row(2, "second"), row(1, "first")])
        data = mcp_tool_data("get_postgres_logs", ref:, limit: 2)
        expect(data).to eq({"logs" => [entry(2, "second"), entry(3, "third")], "next_cursor" => "0196a9f7-0000-7000-8000-000000000002"})

        expect(parseable_client).to receive(:query).with(expected_sql(limit: 3, where: "(\"log_id\" < '0196a9f7-0000-7000-8000-000000000002')"), start_time: String, end_time: String).and_return([row(1, "first")])
        expect(mcp_tool_data("get_postgres_logs", ref:, limit: 2, cursor: data["next_cursor"])).to eq({"logs" => [entry(1, "first")], "next_cursor" => nil})
      end

      it "accepts an integral float limit" do
        expect(parseable_client).to receive(:query).with(expected_sql(limit: 3), start_time: String, end_time: String).and_return([])
        expect(mcp_tool_data("get_postgres_logs", ref:, limit: 2.0)).to eq({"logs" => [], "next_cursor" => nil})
      end

      it "works with a token restricted to Postgres:view" do
        restrict_pat_to("Postgres:view")
        expect(parseable_client).to receive(:query).with(expected_sql, start_time: String, end_time: String).and_return([])
        expect(mcp_tool_data("get_postgres_logs", ref:)).to eq({"logs" => [], "next_cursor" => nil})
      end

      it "reports an unavailable log service" do
        expect(parseable_client).to receive(:query).with(expected_sql, start_time: String, end_time: String).and_raise(Parseable::Client::Error, "connection refused")
        expect(mcp_tool_error("get_postgres_logs", ref:)).to eq "ServiceUnavailable: Log service is temporarily unavailable. Please try again in a few moments."
      end
    end
  end
end
