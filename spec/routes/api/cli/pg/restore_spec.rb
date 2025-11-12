# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Clover, "cli pg restore" do
  before do
    expect(Config).to receive(:postgres_service_project_id).and_return(@project.id).at_least(:once)
  end

  it "schedules a restore of the database to the given time" do
    backup = Struct.new(:key, :last_modified)
    restore_target = Time.now.utc
    expect(MinioCluster).to receive(:first).and_return(instance_double(MinioCluster, url: "dummy-url", root_certs: "dummy-certs")).at_least(:once)
    expect(Minio::Client).to receive(:new).and_return(instance_double(Minio::Client, list_objects: [backup.new("basebackups_005/backup_stop_sentinel.json", restore_target - 10 * 60)])).at_least(:once)

    cli(%w[pg eu-central-h1/test-pg create -s standard-2 -S 64])
    expect(PostgresResource.select_order_map(:name)).to eq %w[test-pg]
    body = cli(%w[pg eu-central-h1/test-pg restore test-pg-2] << Time.now.utc)
    expect(PostgresResource.select_order_map(:name)).to eq %w[test-pg test-pg-2]
    pg = PostgresResource.first(name: "test-pg-2")
    expect(body).to eq "Restored PostgreSQL database scheduled for creation with id: #{pg.ubid}\n"
  end
end
