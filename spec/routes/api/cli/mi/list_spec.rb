# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Clover, "cli mi list" do
  before do
    @project.set_ff_machine_image(true)
    @mi = MachineImage.create(name: "test-mi", project_id: @project.id, arch: "x64",
      location_id: Location[display_name: TEST_LOCATION].id)
  end

  it "shows list of machine images" do
    expect(cli(%w[mi list -N])).to include("test-mi", @mi.ubid, "x64")
  end

  it "shows headers by default" do
    expect(cli(%w[mi list])).to include("location", "name", "id")
  end
end
