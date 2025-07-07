# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Clover, "cli pg destroy" do
  before do
    expect(Config).to receive(:postgres_service_project_id).and_return(@project.id).at_least(:once)
  end

  it "destroys PostgreSQL database" do
    expect(PostgresResource.count).to eq 0
    cli(%w[pg eu-central-h1/test-pg create -s standard-2 -S 64])
    expect(PostgresResource.count).to eq 1
    pg = PostgresResource.first
    expect(pg).to be_a PostgresResource
    expect(Semaphore.where(strand_id: pg.id, name: "destroy")).to be_empty
    expect(cli(%w[pg eu-central-h1/test-pg destroy -f])).to eq "PostgreSQL database, if it exists, is now scheduled for destruction\n"
    expect(Semaphore.where(strand_id: pg.id, name: "destroy")).not_to be_empty
  end
end
