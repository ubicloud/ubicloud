# frozen_string_literal: true

require_relative "../model/spec_helper"

RSpec.describe Prog::Base do
  it "deletes a child with a exitval set" do
    parent = Strand.create(prog: "Test", label: "reaper")
    parent.add_child(exitval: "{}", parent_id: parent.id,
      prog: "Test", label: "start")
    expect {
      parent.run
    }.to change { parent.load.leaf? }.from(false).to(true)
  end

  it "does not delete a child that has no retval yet" do
    parent = Strand.create(prog: "Test", label: "reaper")
    parent.add_child(parent_id: parent.id, prog: "Test", label: "start")

    expect {
      parent.run
    }.not_to change { parent.load.leaf? }.from(false)
  end
end
