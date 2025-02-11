# frozen_string_literal: true

require_relative "../spec_helper"

%w[psql pg_dump pg_dumpall].each do |cmd|
  RSpec.describe Clover, "cli pg #{cmd}" do
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

    it "connects to database via psql" do
      expect(cli_exec(["pg", @ref, cmd])).to eq %W[#{cmd} -- postgres://postgres:#{@pg.superuser_password}@test-pg.#{@pg.ubid}.pg.example.com?channel_binding=require]
    end

    it "supports psql options" do
      expect(cli_exec(["pg", @ref, cmd, "-a"])).to eq %W[#{cmd} -a -- postgres://postgres:#{@pg.superuser_password}@test-pg.#{@pg.ubid}.pg.example.com?channel_binding=require]
    end

    it "supports -U option for user name" do
      expect(cli_exec(["pg", @ref, "-Ufoo", cmd, "-a"])).to eq %W[#{cmd} -a -- postgres://foo@test-pg.#{@pg.ubid}.pg.example.com?channel_binding=require]
    end

    it "supports -d option for database name" do
      expect(cli_exec(["pg", @ref, "-dfoo", cmd, "-a"])).to eq %W[#{cmd} -a -- postgres://postgres:#{@pg.superuser_password}@test-pg.#{@pg.ubid}.pg.example.com/foo?channel_binding=require]
    end
  end
end
