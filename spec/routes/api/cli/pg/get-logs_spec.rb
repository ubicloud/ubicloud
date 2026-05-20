# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Clover, "cli pg get-logs" do
  let(:parseable_client) { instance_double(Parseable::Client) }

  before do
    expect(Config).to receive(:postgres_service_project_id).and_return(@project.id).at_least(:once)
    cli(%w[pg eu-central-h1/test-pg create -s standard-2 -S 64])
    @pg = PostgresResource.first
    expect(ParseableResource).to receive(:client_for_project).and_return(parseable_client).at_least(:once)
  end

  def expected_sql(pg_ubid, limit: 51, where: nil)
    cols = '"log_id", "time_unix_nano", "stream", "severity_text", "body", "instance", "server_role", "remote_host_port", "dbname", "pid", "user"'
    condition = where ? "(\"log_id\" IS NOT NULL) AND (#{where})" : '"log_id" IS NOT NULL'
    "SELECT #{cols} FROM \"#{pg_ubid}\" WHERE (#{condition}) ORDER BY \"log_id\" DESC LIMIT #{limit}"
  end

  it "shows logs in CSV format" do
    rows = [{"log_id" => "abc", "time_unix_nano" => "2026-01-01T00:00:00", "stream" => "postgres", "severity_text" => "INFO", "body" => "database started", "instance" => @pg.representative_server.ubid, "server_role" => "primary"}]
    expect(parseable_client).to receive(:query) do |sql, **|
      expect(sql).to eq expected_sql(@pg.ubid)
      rows
    end

    expect(cli(%w[pg eu-central-h1/test-pg get-logs -N])).to eq "2026-01-01T00:00:00Z,primary,postgres,INFO,database started\n"
  end

  it "shows headers by default" do
    rows = [{"log_id" => "abc", "time_unix_nano" => "2026-01-01T00:00:00", "stream" => "postgres", "severity_text" => "INFO", "body" => "database started", "instance" => @pg.representative_server.ubid, "server_role" => "primary"}]
    expect(parseable_client).to receive(:query) do |sql, **|
      expect(sql).to eq expected_sql(@pg.ubid)
      rows
    end

    expect(cli(%w[pg eu-central-h1/test-pg get-logs])).to eq <<~END
      Timestamp,ServerRole,Stream,Level,Message
      2026-01-01T00:00:00Z,primary,postgres,INFO,database started
    END
  end

  it "filters logs by level" do
    rows = [{"log_id" => "abc", "time_unix_nano" => "2026-01-01T00:00:00", "stream" => "postgres", "severity_text" => "ERROR", "body" => "connection failed", "instance" => @pg.representative_server.ubid, "server_role" => "primary"}]
    expect(parseable_client).to receive(:query) do |sql, **|
      expect(sql).to eq expected_sql(@pg.ubid, where: "\"severity_text\" = 'ERROR'")
      rows
    end

    expect(cli(%w[pg eu-central-h1/test-pg get-logs --severity-level=ERROR -N])).to eq "2026-01-01T00:00:00Z,primary,postgres,ERROR,connection failed\n"
  end

  it "--limit and --pagination-key options work" do
    pk = "0196a9f7-0000-7000-8000-000000000000"
    row1 = {"log_id" => pk, "time_unix_nano" => "2026-01-01T00:00:00", "stream" => "postgres", "severity_text" => "INFO", "body" => "first", "instance" => @pg.representative_server.ubid, "server_role" => "primary"}
    row2 = {"log_id" => "0196a9f7-0000-7000-8000-000000000001", "time_unix_nano" => "2026-01-01T00:00:00", "stream" => "postgres", "severity_text" => "INFO", "body" => "second", "instance" => @pg.representative_server.ubid, "server_role" => "primary"}

    expect(parseable_client).to receive(:query) do |sql, **|
      expect(sql).to eq expected_sql(@pg.ubid, limit: 2)
      [row1, row2]
    end

    expect(cli(%w[pg eu-central-h1/test-pg get-logs -N --max-log-lines=1])).to eq(
      "2026-01-01T00:00:00Z,primary,postgres,INFO,first\n" \
      "Continue search: ubi pg eu-central-h1/test-pg get-logs --max-log-lines=1 --pagination-key=#{pk} \n",
    )

    expect(parseable_client).to receive(:query) do |sql, **|
      expect(sql).to eq expected_sql(@pg.ubid, limit: 2, where: "\"log_id\" < '#{pk}'")
      [row2]
    end

    expect(cli(%W[pg eu-central-h1/test-pg get-logs -N --max-log-lines=1 --pagination-key=#{pk}])).to eq "2026-01-01T00:00:00Z,primary,postgres,INFO,second\n"
  end
end
