# frozen_string_literal: true

require_relative "../../spec_helper"

RSpec.describe Clover, "cli pg ember claim" do
  it "moves an anonymous ember into the project" do
    service_project = Project.create(name: "postgres-ember-service")
    allow(Config).to receive(:ember_service_project_id).and_return(service_project.id)
    ember = create_postgres_ember(project_id: service_project.id, name: "unclaimed",
      claim_token_digest: PostgresEmber.hash_claim_token("tok"))

    expect(cli(%w[pg ember claim tok])).to eq("Claimed PostgreSQL ember with id: #{ember.ubid}\n")
    expect(ember.reload.project_id).to eq(@project.id)
  end

  it "says so when the token matches nothing" do
    allow(Config).to receive(:ember_service_project_id).and_return(Project.create(name: "s").id)
    cli(%w[pg ember claim nosuch], status: 404)
    expect(last_response.body).to include("No unclaimed ember")
  end
end
