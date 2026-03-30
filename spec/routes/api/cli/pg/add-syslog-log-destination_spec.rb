# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Clover, "cli pg add-syslog-log-destination" do
  before do
    expect(Config).to receive(:postgres_service_project_id).and_return(@project.id).at_least(:once)
  end

  it "adds a syslog log destination to the database (default port)" do
    cli(%w[pg eu-central-h1/test-pg create -s standard-2 -S 64])
    pg = PostgresResource.first
    expect(pg.log_destinations_dataset).to be_empty
    body = cli(%w[pg eu-central-h1/test-pg add-syslog-log-destination my-dest logs.example.com])
    ld = pg.log_destinations.first
    expect(body).to eq "Log destination added to PostgreSQL database.\n  id: #{ld.ubid}\n"
    expect(ld.name).to eq "my-dest"
    expect(ld.type).to eq "syslog"
    expect(ld.url).to eq "tcp://logs.example.com:6514"
    expect(ld.options).to eq({"structured_data" => {}})
  end

  it "adds a syslog log destination with explicit port" do
    cli(%w[pg eu-central-h1/test-pg create -s standard-2 -S 64])
    pg = PostgresResource.first
    cli(%w[pg eu-central-h1/test-pg add-syslog-log-destination my-dest logs.example.com 514])
    ld = pg.log_destinations.first
    expect(ld.url).to eq "tcp://logs.example.com:514"
  end

  it "adds a syslog log destination with structured data" do
    cli(%w[pg eu-central-h1/test-pg create -s standard-2 -S 64])
    pg = PostgresResource.first
    cli(["pg", "eu-central-h1/test-pg", "add-syslog-log-destination", "my-dest", "logs.example.com",
      "honeybadger@61642/api_key=secret", "honeybadger@61642/env=prod", "logdna@48950/api_key=abc"])
    ld = pg.log_destinations.first
    expect(ld.options).to eq({
      "structured_data" => {
        "honeybadger@61642" => {"api_key" => "secret", "env" => "prod"},
        "logdna@48950" => {"api_key" => "abc"},
      },
    })
  end

  it "adds a syslog log destination with port and structured data" do
    cli(%w[pg eu-central-h1/test-pg create -s standard-2 -S 64])
    pg = PostgresResource.first
    cli(["pg", "eu-central-h1/test-pg", "add-syslog-log-destination", "my-dest", "logs.example.com", "6514",
      "honeybadger@61642/api_key=secret"])
    ld = pg.log_destinations.first
    expect(ld.url).to eq "tcp://logs.example.com:6514"
    expect(ld.options).to include("structured_data" => {"honeybadger@61642" => {"api_key" => "secret"}})
  end

  it "returns an error for structured_data arg missing slash" do
    cli(%w[pg eu-central-h1/test-pg create -s standard-2 -S 64])
    body = cli(%w[pg eu-central-h1/test-pg add-syslog-log-destination my-dest logs.example.com badarg], status: 400)
    expect(body).to include("Invalid structured_data argument, expected sd-id/key=value format").and include('"badarg"')
  end

  it "returns an error for structured_data arg missing equals" do
    cli(%w[pg eu-central-h1/test-pg create -s standard-2 -S 64])
    body = cli(%w[pg eu-central-h1/test-pg add-syslog-log-destination my-dest logs.example.com sd-id/noequals], status: 400)
    expect(body).to include("Invalid structured_data argument, expected sd-id/key=value format").and include('"sd-id/noequals"')
  end
end
