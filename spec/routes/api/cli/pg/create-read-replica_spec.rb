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
    expect(@project).to receive(:postgres_resources_dataset).and_return(instance_double(Sequel::Dataset, first: pg))
    expect(described_class).to receive(:authorized_project).with(@account, @project.id).and_return(@project)
    expect(@project).to receive(:quota_available?).and_return(true)
    expect(pg).to receive(:ready_for_read_replica?).and_return(true)
    body = cli(%w[pg eu-central-h1/test-pg create-read-replica test-pg-rr])
    pg = PostgresResource.first(name: "test-pg-rr")
    expect(pg.display_location).to eq "eu-central-h1"
    expect(pg.target_vm_size).to eq "standard-2"
    expect(pg.target_storage_size_gib).to eq 64
    expect(pg.ha_type).to eq "none"
    expect(pg.version).to eq "17"
    expect(pg.flavor).to eq "standard"
    expect(pg.tags).to eq([])
    expect(pg.parent_id).to eq(PostgresResource.first(name: "test-pg").id)
    expect(body).to eq "Read replica for PostgreSQL database created with id: #{pg.ubid}\n"
  end
end
