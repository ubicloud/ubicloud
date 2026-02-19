# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Clover, "cli pg create-read-replica" do
  before do
    expect(Config).to receive(:postgres_service_project_id).and_return(@project.id).at_least(:once)
  end

  it "creates a read replica of the postgres database" do
    cli(%w[pg eu-central-h1/test-pg create -s standard-2 -S 64])
    body = cli(%w[pg eu-central-h1/test-pg create-read-replica test-pg-rr], status: 400)
    expect(body).to eq "! Unexpected response status: 400\nDetails: Parent server is not ready for read replicas. There are no backups, yet.\n"

    pg = PostgresResource.first(name: "test-pg")
    server = pg.representative_server
    server.vm.update(family: "standard", vcpus: 2, memory_gib: 8, arch: "x64")
    VmStorageVolume.create(vm_id: server.vm_id, size_gib: 64, boot: false, use_bdev_ubi: false, disk_index: 1)
    pg.timeline.update(cached_earliest_backup_at: Time.now)

    body = cli(%w[pg eu-central-h1/test-pg create-read-replica -c max_connections=99 -u max_client_conn=99 -t foo=bar,baz=quux test-pg-rr])
    pg = PostgresResource.first(name: "test-pg-rr")
    expect(pg.display_location).to eq "eu-central-h1"
    expect(pg.target_vm_size).to eq "standard-2"
    expect(pg.target_storage_size_gib).to eq 64
    expect(pg.ha_type).to eq "none"
    expect(pg.version).to eq "17"
    expect(pg.flavor).to eq "standard"
    expect(pg.user_config).to eq({"max_connections" => "99"})
    expect(pg.pgbouncer_user_config).to eq({"max_client_conn" => "99"})
    expect(pg.tags).to eq([{"key" => "foo", "value" => "bar"}, {"key" => "baz", "value" => "quux"}])
    expect(pg.parent_id).to eq(PostgresResource.first(name: "test-pg").id)
    expect(body).to eq "Read replica for PostgreSQL database created with id: #{pg.ubid}\n"
  end
end
