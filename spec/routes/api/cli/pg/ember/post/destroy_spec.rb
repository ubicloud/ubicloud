# frozen_string_literal: true

require_relative "../../../spec_helper"

RSpec.describe Clover, "cli pg ember destroy" do
  let(:ember) {
    c = create_postgres_ember(project_id: @project.id, name: "one", state: "running")
    Strand.create_with_id(c, prog: "Ember::Nexus", label: "wait")
    c
  }

  it "asks for confirmation first" do
    ember
    cli(%w[pg ember one destroy], confirm_prompt: "Confirmation")
    expect(ember.reload.semaphores).to be_empty
  end

  it "destroys once the name is confirmed" do
    ember
    expect(cli(%w[--confirm one pg ember one destroy])).to include("scheduled for destruction")
    expect(ember.reload.semaphores.map(&:name)).to include("destroy")
  end

  it "refuses a confirmation that does not match" do
    ember
    expect(cli(%w[--confirm wrong pg ember one destroy], status: 400))
      .to eq("! Confirmation of PostgreSQL ember name not successful.\n")
    expect(ember.reload.semaphores).to be_empty
  end

  it "skips the confirmation with -f" do
    ember
    expect(cli(%w[pg ember one destroy -f])).to include("scheduled for destruction")
    expect(ember.reload.semaphores.map(&:name)).to include("destroy")
  end
end
