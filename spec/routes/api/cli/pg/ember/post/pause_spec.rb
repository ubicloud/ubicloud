# frozen_string_literal: true

require_relative "../../../spec_helper"

RSpec.describe Clover, "cli pg ember pause" do
  it "schedules a pause" do
    ember = create_postgres_ember(project_id: @project.id, name: "one", state: "running")
    Strand.create_with_id(ember, prog: "Ember::Nexus", label: "wait")
    expect(cli(%w[pg ember one pause])).to eq("Scheduled pause of PostgreSQL ember with id: #{ember.ubid}\n")
    expect(ember.reload.semaphores.map(&:name)).to include("pause")
  end
end
