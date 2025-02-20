# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Clover, "cli pg failover" do
  before do
    expect(Config).to receive(:postgres_service_project_id).and_return(@project.id).at_least(:once)
  end

  it "fails over PostgreSQL database if a suitable failover target exists" do
    expect(PostgresResource.count).to eq 0
    cli(%w[pg eu-central-h1/test-pg create -h sync -f lantern])
    expect(PostgresResource.count).to eq 1
    pg = PostgresResource.first
    expect(pg).to be_a PostgresResource
    expect(Semaphore.where(name: "take_over")).to be_empty
    expect(cli(%w[pg eu-central-h1/test-pg failover], status: 400)).to eq <<~END
      ! Unexpected response status: 400
      Details: There is not a suitable standby server to failover!
    END
    rs = pg.representative_server
    rs.update(timeline_access: "push")
    st = Prog::Postgres::PostgresServerNexus.assemble(resource_id: pg.id, timeline_id: rs.timeline_id, timeline_access: "fetch")
    st.update(label: "wait")
    expect(PostgresServer).to receive(:run_query).and_return "16/B374D848"

    expect(Semaphore.where(name: "take_over")).to be_empty
    expect(cli(%w[pg eu-central-h1/test-pg failover])).to eq "Failover initiated for PostgreSQL database with id: #{pg.ubid}\n"
    expect(Semaphore.where(name: "take_over")).not_to be_empty
  end
end
