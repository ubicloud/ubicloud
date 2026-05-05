# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Clover, "cli pg get-logs" do
  before do
    expect(Config).to receive(:postgres_service_project_id).and_return(@project.id).at_least(:once)
    cli(%w[pg eu-central-h1/test-pg create -s standard-2 -S 64])
    @pg = PostgresResource.first
    @project.set_ff_postgres_log_aggregation(true)
  end

  it "shows logs in CSV format" do
    rows = [{"log_id" => "abc", "time_unix_nano" => "1000000000", "stream" => "postgres", "severity_text" => "INFO", "body" => "database started", "instance" => @pg.representative_server.ubid, "server_role" => "primary"}]
    parseable_client = instance_double(Parseable::Client)
    expect(PostgresServer).to receive(:parseable_client).and_return(parseable_client).at_least(:once)
    expect(parseable_client).to receive(:query).and_return(rows)

    expect(cli(%w[pg eu-central-h1/test-pg get-logs -N])).to eq "1000000000,primary,postgres,INFO,database started\n"
  end

  it "shows headers by default" do
    rows = [{"log_id" => "abc", "time_unix_nano" => "1000000000", "stream" => "postgres", "severity_text" => "INFO", "body" => "database started", "instance" => @pg.representative_server.ubid, "server_role" => "primary"}]
    parseable_client = instance_double(Parseable::Client)
    expect(PostgresServer).to receive(:parseable_client).and_return(parseable_client).at_least(:once)
    expect(parseable_client).to receive(:query).and_return(rows)

    expect(cli(%w[pg eu-central-h1/test-pg get-logs])).to eq <<~END
      Timestamp,ServerRole,Stream,Level,Message
      1000000000,primary,postgres,INFO,database started
    END
  end

  it "filters logs by level" do
    rows = [{"log_id" => "abc", "time_unix_nano" => "1000000000", "stream" => "postgres", "severity_text" => "ERROR", "body" => "connection failed", "instance" => @pg.representative_server.ubid, "server_role" => "primary"}]
    parseable_client = instance_double(Parseable::Client)
    expect(PostgresServer).to receive(:parseable_client).and_return(parseable_client).at_least(:once)
    expect(parseable_client).to receive(:query) do |sql, **|
      expect(sql).to include("\"severity_text\" = 'ERROR'")
      rows
    end

    expect(cli(%w[pg eu-central-h1/test-pg get-logs --level=ERROR -N])).to eq "1000000000,primary,postgres,ERROR,connection failed\n"
  end

  it "--limit and --pagination-key options work" do
    pk = "0196a9f7-0000-7000-8000-000000000000"
    row1 = {"log_id" => pk, "time_unix_nano" => "1000", "stream" => "postgres", "severity_text" => "INFO", "body" => "first", "instance" => @pg.representative_server.ubid, "server_role" => "primary"}
    row2 = {"log_id" => "0196a9f7-0000-7000-8000-000000000001", "time_unix_nano" => "2000", "stream" => "postgres", "severity_text" => "INFO", "body" => "second", "instance" => @pg.representative_server.ubid, "server_role" => "primary"}

    parseable_client = instance_double(Parseable::Client)
    expect(PostgresServer).to receive(:parseable_client).and_return(parseable_client).at_least(:once)
    expect(parseable_client).to receive(:query).and_return([row1, row2])

    expect(cli(%w[pg eu-central-h1/test-pg get-logs -N --limit=1])).to eq(
      "1000,primary,postgres,INFO,first\n" \
      "Continue search: ubi pg eu-central-h1/test-pg get-logs --limit=1 --pagination-key=#{pk} \n",
    )

    expect(parseable_client).to receive(:query).and_return([row2])

    expect(cli(%W[pg eu-central-h1/test-pg get-logs -N --limit=1 --pagination-key=#{pk}])).to eq "2000,primary,postgres,INFO,second\n"
  end
end
