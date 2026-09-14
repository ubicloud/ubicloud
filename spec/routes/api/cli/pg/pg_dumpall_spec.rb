# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Clover, "cli pg pg_dumpall" do
  before do
    expect(Config).to receive(:postgres_service_project_id).and_return(@project.id).at_least(:once)
    @pg = Prog::Postgres::PostgresResourceNexus.assemble(
      project_id: @project.id,
      location_id: Location::HETZNER_FSN1_ID,
      name: "test-pg",
      target_vm_size: "standard-2",
      target_storage_size_gib: 64,
    ).subject
    @ref = [@pg.display_location, @pg.name].join("/")
    @conn_string = URI("postgres://postgres:#{@pg.superuser_password}@test-pg.#{@pg.ubid}.pg.example.com:5432/postgres?channel_binding=require")
    allow(Config).to receive(:postgres_service_hostname_v3).and_return("pg.example.com").at_least(:once)
    DnsZone.create(project_id: @project.id, name: "pg.example.com")
  end

  it "errors if client version is not 1.1.0+" do
    msg = "! Using the pg pg_dumpall subcommand with your current ubi program is disallowed for security reasons. Please update your ubi program to version 1.1.0+."
    expect(cli(["pg", @ref, "pg_dumpall"], status: 400, env: {})).to start_with(msg)
    expect(cli(["pg", @ref, "pg_dumpall"], status: 400, env: {"HTTP_X_UBI_VERSION" => "1.0.0"})).to start_with(msg)
  end

  it "supports pg_dumpall options" do
    expect(cli_exec(["pg", @ref, "pg_dumpall", "-a"], env: {"HTTP_X_UBI_VERSION" => "1.1.0"}, command_pgpassword: @pg.superuser_password)).to eq %W[pg_dumpall -a -dpostgres://postgres@test-pg.#{@pg.ubid}.pg.example.com:5432/postgres?sslmode=require&channel_binding=require]
  end

  it "connects to database via pg_dumpall" do
    expect(cli_exec(["pg", @ref, "pg_dumpall"], env: {"HTTP_X_UBI_VERSION" => "1.1.0"}, command_pgpassword: @pg.superuser_password)).to eq %W[pg_dumpall -dpostgres://postgres@test-pg.#{@pg.ubid}.pg.example.com:5432/postgres?sslmode=require&channel_binding=require]
  end

  it "supports -U option for user name" do
    expect(cli_exec(["pg", @ref, "-Ufoo", "pg_dumpall", "-a"])).to eq %W[pg_dumpall -a -dpostgres://foo@test-pg.#{@pg.ubid}.pg.example.com:5432/postgres?sslmode=require&channel_binding=require]
  end

  it "supports -d option for database name" do
    expect(cli_exec(["pg", @ref, "-dfoo", "pg_dumpall", "-a"], env: {"HTTP_X_UBI_VERSION" => "1.1.0"}, command_pgpassword: @pg.superuser_password)).to eq %W[pg_dumpall -a -dpostgres://postgres@test-pg.#{@pg.ubid}.pg.example.com:5432/foo?sslmode=require&channel_binding=require]
  end
end
