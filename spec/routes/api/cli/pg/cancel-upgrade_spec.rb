# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Clover, "cli pg cancel-upgrade" do
  before do
    expect(Config).to receive(:postgres_service_project_id).and_return(@project.id).at_least(:once)
    cli(%w[pg eu-central-h1/test-pg create -s standard-2 -S 64 -v 16])
    @pg = PostgresResource.first
    @ref = [@pg.display_location, @pg.name].join("/")
    @pg.update(target_version: "17")
  end

  it "schedules cancel of a failed upgrade" do
    st = Strand.create(parent_id: @pg.strand.id, prog: "Postgres::ConvergePostgresResource", label: "upgrade_failed")
    expect(cli(%W[pg #{@ref} cancel-upgrade])).to eq "Scheduled cancel of the failed upgrade of PostgreSQL database with id #{@pg.ubid}.\n"
    expect(Semaphore.where(strand_id: st.id, name: "cancel_upgrade").count).to eq(1)
  end

  it "fails when the upgrade has not failed" do
    Strand.create(parent_id: @pg.strand.id, prog: "Postgres::ConvergePostgresResource", label: "upgrade_standby")
    expect(cli(%W[pg #{@ref} cancel-upgrade], status: 400)).to eq "! Unexpected response status: 400\nDetails: Only a failed upgrade can be canceled\n"
  end
end
