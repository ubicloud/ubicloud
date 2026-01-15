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
    DnsZone.create(project_id: @project.id, name: "pg.example.com")
    @pg.add_metric_destination(username: "md-user", password: "1", url: "https://md.example.com")
    @pg.update(root_cert_1: "a", root_cert_2: "b")
    @pg.representative_server.vm.add_vm_storage_volume(boot: false, size_gib: 64, disk_index: 0)
    rules = @pg.pg_firewall_rules
    rules[0].update(description: "my fwr desc")

    expect(cli(%W[pg #{@ref} show])).to eq <<~END
      id: #{@pg.ubid}
      name: test-pg
      state: creating
      location: eu-central-h1
      vm-size: standard-2
      target-vm-size: standard-2
      storage-size-gib: 64
      target-storage-size-gib: 64
      version: 17
      target-version: 17
      ha-type: none
      flavor: standard
      connection-string: postgres://postgres:#{@pg.superuser_password}@test-pg.#{@pg.ubid}.pg.example.com:5432/postgres?channel_binding=require
      primary: true
      earliest-restore-time: 
      maintenance-window-start-at: 
      read-replica: false
      parent: 
      tags:
      firewall-rules:
        1: #{rules[0].ubid}  0.0.0.0/0  5432  my fwr desc
        2: #{rules[1].ubid}  0.0.0.0/0  6432  
        3: #{rules[2].ubid}  ::/0  5432  
        4: #{rules[3].ubid}  ::/0  6432  
      metric-destinations:
        1: #{@pg.metric_destinations[0].ubid}  md-user  https://md.example.com
      read-replicas:
      ca-certificates:
      a
      b
    END

    @pg.update(parent_id: @pg.id)
    expect(cli(%W[pg #{@ref} show])).to eq <<~END
      id: #{@pg.ubid}
      name: test-pg
      state: creating
      location: eu-central-h1
      vm-size: standard-2
      target-vm-size: standard-2
      storage-size-gib: 64
      target-storage-size-gib: 64
      version: 17
      target-version: 17
      ha-type: none
      flavor: standard
      connection-string: postgres://postgres:#{@pg.superuser_password}@test-pg.#{@pg.ubid}.pg.example.com:5432/postgres?channel_binding=require
      primary: true
      earliest-restore-time: 
      maintenance-window-start-at: 
      read-replica: true
      parent: eu-central-h1/test-pg
      tags:
      firewall-rules:
        1: #{rules[0].ubid}  0.0.0.0/0  5432  my fwr desc
        2: #{rules[1].ubid}  0.0.0.0/0  6432  
        3: #{rules[2].ubid}  ::/0  5432  
        4: #{rules[3].ubid}  ::/0  6432  
      metric-destinations:
        1: #{@pg.metric_destinations[0].ubid}  md-user  https://md.example.com
      read-replicas:
        eu-central-h1/test-pg
      ca-certificates:
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
