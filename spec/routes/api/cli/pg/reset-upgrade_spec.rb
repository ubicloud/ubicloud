# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Clover, "cli pg reset-upgrade" do
  before do
    expect(Config).to receive(:postgres_service_project_id).and_return(@project.id).at_least(:once)
    cli(%w[pg eu-central-h1/test-pg create -s standard-2 -S 64 -v 16])
    @pg = PostgresResource.first
    @ref = [@pg.display_location, @pg.name].join("/")
    @pg.update(target_version: "17")
  end

  it "schedules reset of a failed upgrade" do
    st = Strand.create(parent_id: @pg.strand.id, prog: "Postgres::ConvergePostgresResource", label: "upgrade_failed")
    expect(cli(%W[pg #{@ref} reset-upgrade])).to eq "Reset of the failed upgrade scheduled for PostgreSQL database with id: #{@pg.ubid}\n"
    expect(Semaphore.where(strand_id: st.id, name: "reset_upgrade").count).to eq(1)
  end

  it "fails when the upgrade has not failed" do
    Strand.create(parent_id: @pg.strand.id, prog: "Postgres::ConvergePostgresResource", label: "upgrade_standby")
    expect(cli(%W[pg #{@ref} reset-upgrade], status: 400)).to include("Only a failed upgrade can be reset")
  end
end
