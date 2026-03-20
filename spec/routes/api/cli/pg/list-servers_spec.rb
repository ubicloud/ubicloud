# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Clover, "cli pg list-servers" do
  before do
    expect(Config).to receive(:postgres_service_project_id).and_return(@project.id).at_least(:once)
    cli(%w[pg eu-central-h1/test-pg create -s standard-2 -S 64])
    @pg = PostgresResource.first
  end

  it "lists servers for a PostgreSQL database" do
    server = @pg.representative_server
    result = cli(%w[pg eu-central-h1/test-pg list-servers -N])
    expect(result).to include(server.ubid)
    expect(result).to include("primary")
  end
end
