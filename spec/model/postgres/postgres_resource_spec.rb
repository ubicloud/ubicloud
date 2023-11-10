# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe PostgresResource do
  subject(:postgres_resource) {
    described_class.new(
      server_name: "pg-server-name",
      superuser_password: "dummy-password"
    )
  }

  it "returns connection string" do
    expect(Config).to receive(:postgres_service_hostname).and_return("postgres.ubicloud.com").at_least(:once)
    expect(postgres_resource.connection_string).to eq("postgres://postgres:dummy-password@pg-server-name.postgres.ubicloud.com")
  end

  it "returns connection string with ip address if config is not set" do
    expect(postgres_resource).to receive(:server).and_return(instance_double(PostgresServer, vm: instance_double(Vm, ephemeral_net4: "1.2.3.4"))).at_least(:once)
    expect(postgres_resource.connection_string).to eq("postgres://postgres:dummy-password@1.2.3.4")
  end

  it "returns connection string as nil if there is no server" do
    expect(postgres_resource).to receive(:server).and_return(nil).at_least(:once)
    expect(postgres_resource.connection_string).to be_nil
  end

  it "hides sensitive and long columns" do
    inspect_output = postgres_resource.inspect
    postgres_resource.class.redacted_columns.each do |column_key|
      expect(inspect_output).not_to include column_key.to_s
    end
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
