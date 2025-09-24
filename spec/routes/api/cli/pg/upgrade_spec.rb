# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Clover, "cli pg upgrade" do
  before do
    expect(Config).to receive(:postgres_service_project_id).and_return(@project.id).at_least(:once)
    cli(%w[pg eu-central-h1/test-pg create -s standard-2 -S 64 -v 16])
    @pg = PostgresResource.first
    vm = @pg.representative_server.vm
    VmStorageVolume.create(vm_id: vm.id, disk_index: 1, size_gib: 64, boot: false)
    @ref = [@pg.display_location, @pg.name].join("/")
  end

  it "schedules upgrade from version 16 to 17" do
    expect(@pg.version).to eq "16"
    expect(@pg.current_version_int).to eq 16
    allow(@pg).to receive(:needs_convergence?).and_return(false)

    expect(cli(%W[pg #{@ref} upgrade])).to eq "Scheduled major version upgrade of PostgreSQL database with id #{@pg.ubid} to version 17.\n"

    @pg.reload
    expect(@pg.version).to eq "17"
    expect(@pg.needs_upgrade?).to be true
  end

  it "fails to upgrade when database cannot be upgraded" do
    @pg.representative_server.update(version: "17")
    @pg.update(version: "17")

    expect(cli(%W[pg #{@ref} upgrade], status: 400)).to match(/Database is already at the latest version/)
  end
end
