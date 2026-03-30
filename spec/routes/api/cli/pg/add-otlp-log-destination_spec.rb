# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Clover, "cli pg add-otlp-log-destination" do
  before do
    expect(Config).to receive(:postgres_service_project_id).and_return(@project.id).at_least(:once)
  end

  it "adds an otlp log destination to the database" do
    cli(%w[pg eu-central-h1/test-pg create -s standard-2 -S 64])
    pg = PostgresResource.first
    expect(pg.log_destinations_dataset).to be_empty
    body = cli(%w[pg eu-central-h1/test-pg add-otlp-log-destination my-dest https://otlp.nr-data.net])
    ld = pg.log_destinations.first
    expect(body).to eq "Log destination added to PostgreSQL database.\n  id: #{ld.ubid}\n"
    expect(ld.name).to eq "my-dest"
    expect(ld.type).to eq "otlp"
    expect(ld.url).to eq "https://otlp.nr-data.net"
    expect(ld.options).to eq({"headers" => {}})
  end

  it "adds an otlp log destination with headers" do
    cli(%w[pg eu-central-h1/test-pg create -s standard-2 -S 64])
    pg = PostgresResource.first
    cli(["pg", "eu-central-h1/test-pg", "add-otlp-log-destination", "my-dest", "https://otlp.nr-data.net",
      "api-key=secret", "X-Custom=val"])
    ld = pg.log_destinations.first
    expect(ld.options).to eq({"headers" => {"api-key" => "secret", "X-Custom" => "val"}})
  end

  it "returns an error for header arg missing equals" do
    cli(%w[pg eu-central-h1/test-pg create -s standard-2 -S 64])
    body = cli(%w[pg eu-central-h1/test-pg add-otlp-log-destination my-dest https://otlp.nr-data.net badarg], status: 400)
    expect(body).to include("Invalid argument, does not include `=`").and include('"badarg"')
  end
end
