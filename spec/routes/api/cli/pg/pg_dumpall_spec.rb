# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Clover, "cli pg pg_dumpall" do
  before do
    expect(Config).to receive(:postgres_service_project_id).and_return(@project.id).at_least(:once)
    @pg = Prog::Postgres::PostgresResourceNexus.assemble(
      project_id: @project.id,
      location: "hetzner-fsn1",
      name: "test-pg",
      target_vm_size: "standard-2",
      target_storage_size_gib: 64
    ).subject
    @ref = [@pg.display_location, @pg.name].join("/")
    @conn_string = URI("postgres://postgres:#{@pg.superuser_password}@test-pg.#{@pg.ubid}.pg.example.com?channel_binding=require")
    expect(Config).to receive(:postgres_service_hostname).and_return("pg.example.com").at_least(:once)
    @dns_zone = DnsZone.new
    expect(Prog::Postgres::PostgresResourceNexus).to receive(:dns_zone).and_return(@dns_zone).at_least(:once)
  end

  it "connects to database via pg_dumpall" do
    expect(cli_exec(["pg", @ref, "pg_dumpall"])).to eq %W[pg_dumpall -dpostgres://postgres:#{@pg.superuser_password}@test-pg.#{@pg.ubid}.pg.example.com?channel_binding=require]
  end

  it "supports pg_dumpall options" do
    expect(cli_exec(["pg", @ref, "pg_dumpall", "-a"])).to eq %W[pg_dumpall -a -dpostgres://postgres:#{@pg.superuser_password}@test-pg.#{@pg.ubid}.pg.example.com?channel_binding=require]
  end

  it "supports -U option for user name" do
    expect(cli_exec(["pg", @ref, "-Ufoo", "pg_dumpall", "-a"])).to eq %W[pg_dumpall -a -dpostgres://foo@test-pg.#{@pg.ubid}.pg.example.com?channel_binding=require]
  end

  it "supports -d option for database name" do
    expect(cli_exec(["pg", @ref, "-dfoo", "pg_dumpall", "-a"])).to eq %W[pg_dumpall -a -dpostgres://postgres:#{@pg.superuser_password}@test-pg.#{@pg.ubid}.pg.example.com/foo?channel_binding=require]
  end
end
