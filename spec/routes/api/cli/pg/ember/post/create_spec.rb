# frozen_string_literal: true

require_relative "../../../spec_helper"

RSpec.describe Clover, "cli pg ember create" do
  before { allow(PostgresEmberOperations).to receive(:create) { |**args| created(args) } }

  it "creates an ember with the given name and reports its connection string" do
    body = cli(%w[pg ember my-ember create])
    ember = PostgresEmber.first
    expect(ember.name).to eq("my-ember")
    expect(body).to include("created with id: #{ember.ubid}")
    expect(body).to include("postgres://postgres")
  end

  it "passes the location, version and database through" do
    passed = nil
    allow(PostgresEmberOperations).to receive(:create) { |**args|
      passed = args
      created(args)
    }
    cli(%w[pg ember my-ember create -l eu-central-h1 -v 17 -d app])
    expect(passed[:pg_version]).to eq("17")
    expect(passed[:database]).to eq("app")
    expect(passed[:location].display_name).to eq("eu-central-h1")
  end

  def created(args)
    create_postgres_ember(project_id: args[:project_id], name: args[:name],
      pg_version: args[:pg_version] || "18", database_name: args[:database] || "postgres",
      state: "running")
  end
end
