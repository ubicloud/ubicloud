# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Clover, "cli mi rename" do
  let(:location_id) { Location[display_name: TEST_LOCATION].id }

  before do
    @project.set_ff_machine_image(true)
    @mi = MachineImage.create(name: "old-name", project_id: @project.id, arch: "x64", location_id:)
  end

  it "renames a machine image" do
    body = cli(%W[mi eu-central-h1/#{@mi.name} rename new-name])
    expect(body).to eq("Machine image renamed to new-name\n")
    expect(@mi.reload.name).to eq("new-name")
  end
end
