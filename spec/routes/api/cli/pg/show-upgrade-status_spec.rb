# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Clover, "cli pg show-upgrade-status" do
  before do
    expect(Config).to receive(:postgres_service_project_id).and_return(@project.id).at_least(:once)
    @pg = Prog::Postgres::PostgresResourceNexus.assemble(
      project_id: @project.id,
      location_id: Location::HETZNER_FSN1_ID,
      name: "test-pg",
      target_vm_size: "standard-2",
      target_storage_size_gib: 64,
      target_version: 16
    ).subject
    @ref = [@pg.display_location, @pg.name].join("/")
  end

  it "raises error when database is not upgrading" do
    expect(cli(%W[pg #{@ref} show-upgrade-status], status: 400)).to match(/Database is not upgrading/)
  end

  it "shows upgrade status when database needs upgrade" do
    @pg.update(target_version: 17)
    @pg.strand.children_dataset.where(prog: "Postgres::ConvergePostgresResource").first&.update(label: "start")

    output = cli(%W[pg #{@ref} show-upgrade-status])
    expect(output).to include("Major version upgrade of PostgreSQL database #{@pg.ubid} to version 17")
    expect(output).to include("Status: running")
  end

  it "shows upgrade status when upgrade failed" do
    @pg.update(target_version: 17)
    Strand.create(parent_id: @pg.strand.id, prog: "Postgres::ConvergePostgresResource", label: "upgrade_failed")

    output = cli(%W[pg #{@ref} show-upgrade-status])
    expect(output).to include("Major version upgrade of PostgreSQL database #{@pg.ubid} to version 17")
    expect(output).to include("Status: failed")
  end
end
