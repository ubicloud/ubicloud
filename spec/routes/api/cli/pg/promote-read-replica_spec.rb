# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Clover, "cli pg promote-read-replica" do
  before do
    expect(Config).to receive(:postgres_service_project_id).and_return(@project.id).at_least(:once)
    cli(%w[pg eu-central-h1/test-pg create -s standard-2 -S 64])
    cli(%w[pg eu-central-h1/test-pg-rr create -s standard-2 -S 64])
    @pg = PostgresResource.first(name: "test-pg-rr").update(parent_id: PostgresResource.where(name: "test-pg").get(:id))
  end

  it "promotes postgres database from read replica to primary" do
    expect(Semaphore.where(strand_id: @pg.id, name: "promote")).to be_empty
    expect(cli(%w[pg eu-central-h1/test-pg-rr promote-read-replica])).to eq "Promoted PostgreSQL database with id #{@pg.ubid} from read replica to primary.\n"
    expect(Semaphore.where(strand_id: @pg.id, name: "promote")).not_to be_empty
  end
end
