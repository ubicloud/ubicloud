# frozen_string_literal: true

require_relative "../../../spec_helper"

RSpec.describe Clover, "cli pg ember resume" do
  it "resumes and reports the state it came back in" do
    ember = create_postgres_ember(project_id: @project.id, name: "one", state: "paused")
    expect(EmberOperations).to receive(:resume) { ember.ember.update(state: "running") }
    expect(cli(%w[pg ember one resume])).to eq("PostgreSQL ember with id #{ember.ubid} is running\n")
  end
end
