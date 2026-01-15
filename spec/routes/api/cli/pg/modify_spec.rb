# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Clover, "cli pg modify" do
  before do
    expect(Config).to receive(:postgres_service_project_id).and_return(@project.id).at_least(:once)
    cli(%w[pg eu-central-h1/test-pg create -s standard-2 -S 64 -h async])
    expect(PostgresResource.count).to eq 1
    @pg = PostgresResource.first
    expect(@pg.target_vm_size).to eq "standard-2"
    expect(@pg.target_storage_size_gib).to eq 64
    expect(@pg.ha_type).to eq "async"
  end

  it "modifies PostgreSQL database without changing tags" do
    body = cli(%w[pg eu-central-h1/test-pg modify -s standard-4 -S 128 -h sync])
    expect(PostgresResource.count).to eq 1
    @pg.reload
    expect(@pg.target_vm_size).to eq "standard-4"
    expect(@pg.target_storage_size_gib).to eq 128
    expect(@pg.ha_type).to eq "sync"
    expect(@pg.tags).to eq([])
    expect(body).to eq "Modified PostgreSQL database with id: #{@pg.ubid}\n"
  end

  it "modifies PostgreSQL database tags" do
    body = cli(%w[pg eu-central-h1/test-pg modify -t foo=bar,baz=quux])
    expect(PostgresResource.count).to eq 1
    @pg.reload
    expect(@pg.target_vm_size).to eq "standard-2"
    expect(@pg.target_storage_size_gib).to eq 64
    expect(@pg.ha_type).to eq "async"
    expect(@pg.tags).to eq([{"key" => "foo", "value" => "bar"}, {"key" => "baz", "value" => "quux"}])
    expect(body).to eq "Modified PostgreSQL database with id: #{@pg.ubid}\n"

    body = cli(%w[pg eu-central-h1/test-pg modify -t] << "")
    expect(PostgresResource.count).to eq 1
    @pg.reload
    expect(@pg.target_vm_size).to eq "standard-2"
    expect(@pg.target_storage_size_gib).to eq 64
    expect(@pg.ha_type).to eq "async"
    expect(@pg.tags).to eq([])
    expect(body).to eq "Modified PostgreSQL database with id: #{@pg.ubid}\n"
  end
end
