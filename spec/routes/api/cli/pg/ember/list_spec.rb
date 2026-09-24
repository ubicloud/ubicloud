# frozen_string_literal: true

require_relative "../../spec_helper"

RSpec.describe Clover, "cli pg ember list" do
  it "lists the project's embers" do
    ember = create_postgres_ember(project_id: @project.id, name: "one", state: "running")
    body = cli(%w[pg ember list])
    expect(body).to include("one", ember.ubid, "running", "18")
    expect(body).to start_with("id")
  end

  it "leaves the headers out when asked" do
    create_postgres_ember(project_id: @project.id, name: "one")
    expect(cli(%w[pg ember list -N])).not_to start_with("id")
  end
end
