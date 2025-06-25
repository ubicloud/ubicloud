# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Clover, "cli pg delete-metric-destination" do
  before do
    expect(Config).to receive(:postgres_service_project_id).and_return(@project.id).at_least(:once)
  end

  it "deletes the specified metric destination for the database" do
    cli(%w[pg eu-central-h1/test-pg create -s standard-2 -S 64])
    cli(%w[pg eu-central-h1/test-pg add-metric-destination foo bar https://baz.example.com])
    pg = PostgresResource.first
    md = pg.metric_destinations.first
    expect(cli(%w[pg eu-central-h1/test-pg delete-metric-destination a/b], status: 400)).to start_with "! Invalid metric destination id format\n"
    expect(pg.metric_destinations_dataset).not_to be_empty
    expect(cli(%W[pg eu-central-h1/test-pg delete-metric-destination #{md.ubid}])).to eq "Metric destination, if it exists, has been scheduled for deletion\n"
    expect(pg.metric_destinations_dataset).to be_empty
  end
end
