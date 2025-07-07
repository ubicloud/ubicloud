# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Clover, "cli pg add-metric-destination" do
  before do
    expect(Config).to receive(:postgres_service_project_id).and_return(@project.id).at_least(:once)
  end

  it "adds a metric desintation to the database" do
    cli(%w[pg eu-central-h1/test-pg create -s standard-2 -S 64])
    pg = PostgresResource.first
    expect(pg.metric_destinations_dataset).to be_empty
    body = cli(%w[pg eu-central-h1/test-pg add-metric-destination foo bar https://baz.example.com])
    expect(pg.metric_destinations_dataset.count).to eq 1
    md = pg.metric_destinations.first
    expect(body).to eq <<~END
      Metric destination added to PostgreSQL database.
      Current metric destinations:
        1: #{md.ubid}  foo  https://baz.example.com
    END
    expect(md.username).to eq "foo"
    expect(md.password).to eq "bar"
    expect(md.url).to eq "https://baz.example.com"
  end
end
