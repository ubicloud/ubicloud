# frozen_string_literal: true

require_relative "../spec_helper"

%w[psql pg_dump].each do |cmd|
  RSpec.describe Clover, "cli pg #{cmd}" do
    before do
      expect(Config).to receive(:postgres_service_project_id).and_return(@project.id).at_least(:once)
      @pg = Prog::Postgres::PostgresResourceNexus.assemble(
        project_id: @project.id,
        location_id: Location::HETZNER_FSN1_ID,
        name: "test-pg",
        target_vm_size: "standard-2",
        target_storage_size_gib: 64,
        desired_version: "16"
      ).subject
      @ref = [@pg.display_location, @pg.name].join("/")
      @conn_string = URI("postgres://postgres:#{@pg.superuser_password}@test-pg.#{@pg.ubid}.pg.example.com:5432/postgres?sslmode=require")
      expect(Config).to receive(:postgres_service_hostname).and_return("pg.example.com").at_least(:once)
      DnsZone.create(project_id: @project.id, name: "pg.example.com")
    end

    it "connects to database via #{cmd}" do
      expect(cli_exec(["pg", @ref, cmd])).to eq %W[#{cmd} -- postgres://postgres:#{@pg.superuser_password}@test-pg.#{@pg.ubid}.pg.example.com:5432/postgres?sslmode=require]
    end

    it "puts password in ubi-pgpassword if client is 1.1.0+" do
      expect(cli_exec(["pg", @ref, cmd], env: {"HTTP_X_UBI_VERSION" => "1.1.0"}, command_pgpassword: @pg.superuser_password)).to eq %W[#{cmd} -- postgres://postgres@test-pg.#{@pg.ubid}.pg.example.com:5432/postgres?sslmode=require]
    end

    it "supports #{cmd} options" do
      expect(cli_exec(["pg", @ref, cmd, "-a"])).to eq %W[#{cmd} -a -- postgres://postgres:#{@pg.superuser_password}@test-pg.#{@pg.ubid}.pg.example.com:5432/postgres?sslmode=require]
    end

    it "supports -U option for user name" do
      expect(cli_exec(["pg", @ref, "-Ufoo", cmd, "-a"])).to eq %W[#{cmd} -a -- postgres://foo@test-pg.#{@pg.ubid}.pg.example.com:5432/postgres?sslmode=require]
    end

    it "supports -d option for database name" do
      expect(cli_exec(["pg", @ref, "-dfoo", cmd, "-a"])).to eq %W[#{cmd} -a -- postgres://postgres:#{@pg.superuser_password}@test-pg.#{@pg.ubid}.pg.example.com:5432/foo?sslmode=require]
    end
  end
end
