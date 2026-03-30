# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Clover, "cli pg delete-log-destination" do
  before do
    expect(Config).to receive(:postgres_service_project_id).and_return(@project.id).at_least(:once)
  end

  it "deletes the specified log destination for the database" do
    cli(%w[pg eu-central-h1/test-pg create -s standard-2 -S 64])
    cli(%w[pg eu-central-h1/test-pg add-syslog-log-destination my-dest logs.example.com])
    pg = PostgresResource.first
    ld = pg.log_destinations.first
    expect(cli(%w[pg eu-central-h1/test-pg delete-log-destination a/b], status: 400)).to start_with "! Invalid log destination id format\n"
    expect(pg.log_destinations_dataset).not_to be_empty
    2.times do
      expect(cli(%W[pg eu-central-h1/test-pg delete-log-destination #{ld.ubid}])).to eq "Log destination, if it exists, has been scheduled for deletion\n"
      expect(pg.log_destinations_dataset).to be_empty
    end
  end
end
