# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Clover, "cli pg create" do
  before do |example|
    next if example.metadata[:no_assemble]
    expect(Config).to receive(:postgres_service_project_id).and_return(@project.id).at_least(:once)
  end

  def enable_network_cache
    @project.set_ff_visible_locations(["us-west-2"])
    @project.set_ff_postgres_network_cache_storage(true)
    aws = Location.first(name: "us-west-2")
    LocationCredentialAws.create(access_key: "access-key-id", secret_key: "secret-access-key") { it.id = aws.id }
    LocationAz.create(location_id: aws.id, az: "a", zone_id: "usw2-az1")
    # serialize on AWS reads S3 backups, which is unreachable in tests
    expect(PostgresTimeline).to receive(:earliest_restore_time).and_return(nil).at_least(:once)
  end

  it "creates PostgreSQL database with no options" do
    expect(PostgresResource.count).to eq 0
    body = cli(%w[pg eu-central-h1/test-pg create -s standard-2 -S 64])
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
    expect(pg.pg_firewall_rules_dataset.count).to eq 4
    expect(pg.tags).to eq([])
    expect(body).to eq "PostgreSQL database created with id: #{pg.ubid}\n"
  end

  it "creates PostgreSQL database with all options" do
    expect(PostgresResource.count).to eq 0
    body = cli(%w[pg eu-central-h1/test-pg create -s standard-4 -S 128 -h async -v 17 -c max_connections=100,wal_level=logical -u max_client_conn=100 -f standard -R -t foo=bar,baz=quux])
    expect(PostgresResource.count).to eq 1
    pg = PostgresResource.first
    expect(pg).to be_a PostgresResource
    expect(pg.name).to eq "test-pg"
    expect(pg.display_location).to eq "eu-central-h1"
    expect(pg.target_vm_size).to eq "standard-4"
    expect(pg.target_storage_size_gib).to eq 128
    expect(pg.ha_type).to eq "async"
    expect(pg.version).to eq "17"
    expect(pg.user_config).to eq({"max_connections" => "100", "wal_level" => "logical"})
    expect(pg.pgbouncer_user_config).to eq({"max_client_conn" => "100"})
    expect(pg.flavor).to eq "standard"
    expect(pg.pg_firewall_rules_dataset.count).to eq 0
    expect(pg.tags).to eq([{"key" => "foo", "value" => "bar"}, {"key" => "baz", "value" => "quux"}])
    expect(body).to eq "PostgreSQL database created with id: #{pg.ubid}\n"
  end

  it "creates PostgreSQL database with explicit instance storage type" do
    body = cli(%w[pg eu-central-h1/test-pg create -s standard-2 -S 64 -T instance_storage])
    pg = PostgresResource.first
    expect(pg.storage_type).to eq "instance_storage"
    expect(pg.network_volume_type).to be_nil
    expect(body).to eq "PostgreSQL database created with id: #{pg.ubid}\n"
  end

  it "creates network_cache PostgreSQL database with network volume type" do
    enable_network_cache
    body = cli(%w[pg us-west-2/test-pg create -s m8gd.large -S 64 -T network_cache -N io2])
    pg = PostgresResource.first
    expect(pg.storage_type).to eq "network_cache"
    expect(pg.network_volume_type).to eq "io2"
    expect(body).to eq "PostgreSQL database created with id: #{pg.ubid}\n"
  end

  it "defaults network volume type for network_cache when not given" do
    enable_network_cache
    cli(%w[pg us-west-2/test-pg create -s m8gd.large -S 64 -T network_cache])
    expect(PostgresResource.first.network_volume_type).to eq "gp3"
  end

  it "creates network_cache PostgreSQL database with explicit WAL drive type" do
    enable_network_cache
    body = cli(%w[pg us-west-2/test-pg create -s m8gd.large -S 64 -T network_cache -W io2])
    pg = PostgresResource.first
    expect(pg.storage_type).to eq "network_cache"
    expect(pg.wal_drive_type).to eq "io2"
    expect(body).to eq "PostgreSQL database created with id: #{pg.ubid}\n"
  end

  it "creates network_cache PostgreSQL database with WAL carved from instance NVMe" do
    enable_network_cache
    body = cli(%w[pg us-west-2/test-pg create -s m8gd.large -S 64 -T network_cache -W nvme -w 32])
    pg = PostgresResource.first
    expect(pg.wal_drive_type).to eq "nvme"
    expect(pg.wal_drive_size_gib).to eq 32
    expect(body).to eq "PostgreSQL database created with id: #{pg.ubid}\n"
  end

  it "rejects wal drive size without an nvme WAL drive", :no_assemble do
    body = cli(%w[pg eu-central-h1/test-pg create -s standard-2 -S 64 -w 32], status: 400)
    expect(PostgresResource.count).to eq 0
    expect(body).to start_with("! ")
    expect(body).to include("wal_drive_size_gib requires wal_drive_type nvme")
  end

  it "rejects wal drive size exceeding half the instance store", :no_assemble do
    @project.set_ff_visible_locations(["us-west-2"])
    @project.set_ff_postgres_network_cache_storage(true)
    body = cli(%w[pg us-west-2/test-pg create -s m8gd.large -S 64 -T network_cache -W nvme -w 64], status: 400)
    expect(PostgresResource.count).to eq 0
    expect(body).to start_with("! ")
  end

  it "creates PostgreSQL database with custom private subnet name" do
    expect(PostgresResource.count).to eq 0
    body = cli(%w[pg eu-central-h1/test-pg create -s standard-2 -S 64 -P my-custom-subnet])
    expect(PostgresResource.count).to eq 1
    pg = PostgresResource.first
    expect(pg).to be_a PostgresResource
    expect(pg.name).to eq "test-pg"
    expect(pg.private_subnet.name).to eq "my-custom-subnet"
    expect(body).to eq "PostgreSQL database created with id: #{pg.ubid}\n"
  end

  # rejected input fails validation before assemble, so postgres_service_project_id is never read
  it "rejects network_cache storage type when not available", :no_assemble do
    body = cli(%w[pg eu-central-h1/test-pg create -s standard-2 -S 64 -T network_cache -N io2], status: 400)
    expect(PostgresResource.count).to eq 0
    expect(body).to start_with("! ")
  end
end
