# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Clover, "cli pg rename" do
  it "renames PostgreSQL database" do
    expect(Config).to receive(:postgres_service_project_id).and_return(@project.id).at_least(:once)
    cli(%w[pg eu-central-h1/test-pg create -s standard-2 -S 64])
    expect(cli(%w[pg eu-central-h1/test-pg rename new-name])).to eq "PostgreSQL database renamed to new-name\n"
    expect(PostgresResource.first.name).to eq "new-name"
  end
end
