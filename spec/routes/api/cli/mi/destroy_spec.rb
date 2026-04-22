# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Clover, "cli mi destroy" do
  let(:location_id) { Location[display_name: TEST_LOCATION].id }

  before do
    @project.set_ff_machine_image(true)
    @mi = MachineImage.create(name: "test-mi", project_id: @project.id, arch: "x64", location_id:)
  end

  it "destroys a machine image with -f" do
    expect(cli(%w[mi eu-central-h1/test-mi destroy -f])).to eq(
      "Machine image, if it exists, is now scheduled for destruction\n",
    )
    expect(MachineImage[id: @mi.id]).to be_nil
  end
end
