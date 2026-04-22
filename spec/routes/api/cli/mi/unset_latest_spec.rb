# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Clover, "cli mi unset-latest" do
  let(:location_id) { Location[display_name: TEST_LOCATION].id }

  before do
    @project.set_ff_machine_image(true)
    @mi_metal = create_machine_image_version_metal(project_id: @project.id, location_id:)
    @mi = @mi_metal.machine_image_version.machine_image
    @mi.update(latest_version_id: @mi_metal.machine_image_version.id)
  end

  it "unsets the latest version" do
    body = cli(%W[mi eu-central-h1/#{@mi.name} unset-latest])
    expect(body).to eq("Machine image latest version unset\n")
    expect(@mi.reload.latest_version_id).to be_nil
  end
end
