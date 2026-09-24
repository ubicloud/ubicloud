# frozen_string_literal: true

require_relative "../../../spec_helper"

RSpec.describe Clover, "cli pg ember show" do
  it "shows the details and the connection string" do
    ember = create_postgres_ember(project_id: @project.id, name: "one", state: "running")
    body = cli(%w[pg ember one show])
    expect(body).to include("id: #{ember.ubid}", "name: one", "state: running",
      "version: 18", "database: postgres", "connection string: postgres://")
  end

  it "refuses a reference with a location in it" do
    cli(%w[pg ember eu-central-h1/one show], status: 400)
    expect(last_response.body).to include("Invalid ember reference")
  end
end
