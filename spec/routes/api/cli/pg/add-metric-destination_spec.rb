# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Clover, "cli pg add-metric-destination" do
  before do
    expect(Config).to receive(:postgres_service_project_id).and_return(@project.id).at_least(:once)
  end

  it "adds a basic auth metric destination with 3 positional args" do
    cli(%w[pg eu-central-h1/test-pg create -s standard-2 -S 64])
    pg = PostgresResource.first
    expect(pg.metric_destinations_dataset).to be_empty
    body = cli(%w[pg eu-central-h1/test-pg add-metric-destination foo bar https://baz.example.com])
    expect(pg.metric_destinations_dataset.count).to eq 1
    md = pg.metric_destinations.first
    expect(body).to eq <<~END
      Metric destination added to PostgreSQL database.
      Current metric destinations:
        1: #{md.ubid}  basic  foo  https://baz.example.com
    END
    expect(md.auth_type).to eq "basic"
    expect(md.username).to eq "foo"
    expect(md.password).to eq "bar"
    expect(md.url).to eq "https://baz.example.com"
  end

  it "adds a bearer auth metric destination with 2 positional args" do
    cli(%w[pg eu-central-h1/test-pg create -s standard-2 -S 64])
    pg = PostgresResource.first
    body = cli(%w[pg eu-central-h1/test-pg add-metric-destination -a bearer https://baz.example.com my_token])
    md = pg.metric_destinations.first
    expect(body).to eq <<~END
      Metric destination added to PostgreSQL database.
      Current metric destinations:
        1: #{md.ubid}  bearer  https://baz.example.com
    END
    expect(md.auth_type).to eq "bearer"
    expect(md.username).to be_nil
    expect(md.password).to eq "my_token"
  end
end
