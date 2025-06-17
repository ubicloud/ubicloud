# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Clover, "cli pg restart" do
  before do
    expect(Config).to receive(:postgres_service_project_id).and_return(@project.id).at_least(:once)
    cli(%w[pg eu-central-h1/test-pg create -s standard-2 -S 64])
    @pg = PostgresResource.first
  end

  it "restarts postgres database" do
    expect(Semaphore.where(strand_id: @pg.servers.first.id, name: "restart")).to be_empty
    expect(cli(%w[pg eu-central-h1/test-pg restart])).to eq "Scheduled restart of PostgreSQL database with id #{@pg.ubid}\n"
    expect(Semaphore.where(strand_id: @pg.servers.first.id, name: "restart")).not_to be_empty
  end
end
