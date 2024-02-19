# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe PostgresResource do
  subject(:postgres_resource) {
    described_class.new(
      name: "pg-name",
      superuser_password: "dummy-password"
    ) { _1.id = "6181ddb3-0002-8ad0-9aeb-084832c9273b" }
  }

  it "returns connection string" do
    expect(Prog::Postgres::PostgresResourceNexus).to receive(:dns_zone).and_return("something").at_least(:once)
    expect(postgres_resource.connection_string).to eq("postgres://postgres:dummy-password@pg-name.postgres.ubicloud.com?channel_binding=require")
  end

  it "returns connection string with ip address if config is not set" do
    expect(postgres_resource).to receive(:representative_server).and_return(instance_double(PostgresServer, vm: instance_double(Vm, ephemeral_net4: "1.2.3.4"))).at_least(:once)
    expect(postgres_resource.connection_string).to eq("postgres://postgres:dummy-password@1.2.3.4?channel_binding=require")
  end

  it "returns connection string as nil if there is no server" do
    expect(postgres_resource).to receive(:representative_server).and_return(nil).at_least(:once)
    expect(postgres_resource.connection_string).to be_nil
  end

  it "returns replication_connection_string" do
    s = postgres_resource.replication_connection_string(application_name: "pgubidstandby")
    expect(s).to include("ubi_replication@pgc60xvcr00a5kbnggj1js4kkq.postgres.ubicloud.com", "application_name=pgubidstandby", "sslcert=/dat/16/data/server.crt")
  end

  it "returns running as display state if the database is ready" do
    expect(postgres_resource).to receive(:strand).and_return(instance_double(Strand, label: "wait"))
    expect(postgres_resource.display_state).to eq("running")
  end

  it "returns deleting as display state if the database is being destroyed" do
    expect(postgres_resource).to receive(:strand).and_return(instance_double(Strand, label: "destroy")).twice
    expect(postgres_resource.display_state).to eq("deleting")
  end

  it "returns creating as display state for other cases" do
    expect(postgres_resource).to receive(:strand).and_return(instance_double(Strand, label: "wait_server")).twice
    expect(postgres_resource.display_state).to eq("creating")
  end
end
