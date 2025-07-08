# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Clover, "cli pg show" do
  before do
    expect(Config).to receive(:postgres_service_project_id).and_return(@project.id).at_least(:once)
    @pg = Prog::Postgres::PostgresResourceNexus.assemble(
      project_id: @project.id,
      location_id: Location::HETZNER_FSN1_ID,
      name: "test-pg",
      target_vm_size: "standard-2",
      target_storage_size_gib: 64
    ).subject
    @ref = [@pg.display_location, @pg.name].join("/")
  end

  it "shows information for PostgreSQL database" do
    expect(Config).to receive(:postgres_service_hostname).and_return("pg.example.com").at_least(:once)
    @dns_zone = DnsZone.new
    expect(Prog::Postgres::PostgresResourceNexus).to receive(:dns_zone).and_return(@dns_zone).at_least(:once)
    @pg.add_metric_destination(username: "md-user", password: "1", url: "https://md.example.com")
    @pg.update(root_cert_1: "a", root_cert_2: "b")
    @pg.representative_server.vm.add_vm_storage_volume(boot: false, size_gib: 64, disk_index: 0)

    expect(cli(%W[pg #{@ref} show])).to eq <<~END
      id: #{@pg.ubid}
      name: test-pg
      state: creating
      location: eu-central-h1
      vm_size: standard-2
      target_vm_size: standard-2
      storage_size_gib: 64
      target_storage_size_gib: 64
      version: 17
      ha_type: none
      flavor: standard
      connection_string: postgres://postgres:#{@pg.superuser_password}@test-pg.#{@pg.ubid}.pg.example.com:5432/postgres?sslmode=require
      primary: true
      earliest_restore_time: 
      firewall rules:
        1: #{@pg.firewall_rules[0].ubid}  0.0.0.0/0
      metric destinations:
        1: #{@pg.metric_destinations[0].ubid}  md-user  https://md.example.com
      CA certificates:
      a
      b
    END
  end

  it "-f option controls which fields are shown for the PostgreSQL database" do
    expect(cli(%W[pg #{@ref} show -f id,name])).to eq <<~END
      id: #{@pg.ubid}
      name: test-pg
    END
  end
end
