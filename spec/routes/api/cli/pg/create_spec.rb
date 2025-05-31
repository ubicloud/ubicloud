# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Clover, "cli pg create" do
  before do
    expect(Config).to receive(:postgres_service_project_id).and_return(@project.id).at_least(:once)
  end

  it "creates PostgreSQL database with no options" do
    expect(PostgresResource.count).to eq 0
    body = cli(%w[pg eu-central-h1/test-pg create])
    expect(PostgresResource.count).to eq 1
    pg = PostgresResource.first
    expect(pg).to be_a PostgresResource
    expect(pg.name).to eq "test-pg"
    expect(pg.display_location).to eq "eu-central-h1"
    expect(pg.target_vm_size).to eq "standard-2"
    expect(pg.target_storage_size_gib).to eq 64
    expect(pg.ha_type).to eq "none"
    expect(pg.version).to eq "17"
    expect(pg.flavor).to eq "standard"
    expect(body).to eq "PostgreSQL database created with id: #{pg.ubid}\n"
  end

  it "creates PostgreSQL database with all options" do
    expect(PostgresResource.count).to eq 0
    body = cli(%w[pg eu-central-h1/test-pg create -s standard-4 -S 128 -h async -v 17 -f paradedb])
    expect(PostgresResource.count).to eq 1
    pg = PostgresResource.first
    expect(pg).to be_a PostgresResource
    expect(pg.name).to eq "test-pg"
    expect(pg.display_location).to eq "eu-central-h1"
    expect(pg.target_vm_size).to eq "standard-4"
    expect(pg.target_storage_size_gib).to eq 128
    expect(pg.ha_type).to eq "async"
    expect(pg.version).to eq "17"
    expect(pg.flavor).to eq "paradedb"
    expect(body).to eq "PostgreSQL database created with id: #{pg.ubid}\n"
  end
end
