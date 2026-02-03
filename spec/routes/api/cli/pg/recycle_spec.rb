# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Clover, "cli pg recycle" do
  before do
    expect(Config).to receive(:postgres_service_project_id).and_return(@project.id).at_least(:once)
    cli(%w[pg eu-central-h1/test-pg create -s standard-2 -S 64])
    @pg = PostgresResource.first
  end

  it "recycles primary of postgres database" do
    expect { expect(cli(%w[pg eu-central-h1/test-pg recycle])).to eq("Recycle requested for PostgreSQL database with id #{@pg.ubid}\n") }
      .to change { Semaphore.where(strand_id: @pg.servers.first.id, name: "recycle").count }.from(0).to(1)
  end
end
