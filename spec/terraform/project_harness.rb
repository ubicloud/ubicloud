# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe "terraform: ubicloud_project (generated)" do
  it "creates with a server-assigned id and destroys" do
    runner = tf_runner("project_basic.tf.erb", name: "tf-made")
    runner.apply

    made = Project.first(name: "tf-made")
    tf_grant_pat!(made)
    attrs = runner.state_resources.find { it["address"] == "ubicloud_project.pj" }["values"]
    expect(attrs["id"]).to eq made.ubid
    expect(attrs["name"]).to eq "tf-made"

    runner.destroy

    expect(runner.state_resources).to be_nil
    gone = Project.first(name: "tf-made")
    expect(gone.nil? || !gone.visible).to be true
  end
end
