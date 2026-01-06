# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Clover, "cli pg create" do
  before do
    expect(Config).to receive(:postgres_service_project_id).and_return(@project.id).at_least(:once)
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
    expect(pg.customer_firewall).to be_nil
    expect(pg.tags).to eq([])
    expect(body).to eq <<END
PostgreSQL database created with id: #{pg.ubid}

No access is allowed to this database by default. To allow access, create a
firewall, attach it to the database's private subnet, and add firewall rules
to the firewall:

  ubi fw eu-central-h1/YOUR-FIREWALL-NAME create
  ubi fw eu-central-h1/YOUR-FIREWALL-NAME attach-subnet #{pg.ubid}-subnet
  ubi fw eu-central-h1/YOUR-FIREWALL-NAME add-rule -s 5432 CIDR-TO-ALLOW
END
  end

  it "creates PostgreSQL database with all options" do
    expect(PostgresResource.count).to eq 0
    body = cli(%w[pg eu-central-h1/test-pg create -s standard-4 -S 128 -h async -v 17 -c max_connections=100,wal_level=logical -u max_client_conn=100 -f paradedb -R -t foo=bar,baz=quux])
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
    expect(pg.flavor).to eq "paradedb"
    expect(pg.customer_firewall).to be_nil
    expect(pg.tags).to eq([{"key" => "foo", "value" => "bar"}, {"key" => "baz", "value" => "quux"}])
    expect(body).to include "PostgreSQL database created with id: #{pg.ubid}\n"
  end

  it "creates PostgreSQL database with custom private subnet name" do
    expect(PostgresResource.count).to eq 0
    body = cli(%w[pg eu-central-h1/test-pg create -s standard-2 -S 64 -P my-custom-subnet])
    expect(PostgresResource.count).to eq 1
    pg = PostgresResource.first
    expect(pg).to be_a PostgresResource
    expect(pg.name).to eq "test-pg"
    expect(pg.customer_firewall).to be_nil
    expect(pg.private_subnet.name).to eq "my-custom-subnet"
    expect(body).to eq <<END
PostgreSQL database created with id: #{pg.ubid}

No access is allowed to this database by default. To allow access, create a
firewall, attach it to the database's private subnet, and add firewall rules
to the firewall:

  ubi fw eu-central-h1/YOUR-FIREWALL-NAME create
  ubi fw eu-central-h1/YOUR-FIREWALL-NAME attach-subnet my-custom-subnet
  ubi fw eu-central-h1/YOUR-FIREWALL-NAME add-rule -s 5432 CIDR-TO-ALLOW
END
  end
end
