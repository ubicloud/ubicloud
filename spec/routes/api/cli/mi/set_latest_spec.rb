# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Clover, "cli mi set-latest" do
  let(:location_id) { Location[display_name: TEST_LOCATION].id }

  before do
    @project.set_ff_machine_image(true)
    @mi_metal = create_machine_image_version_metal(project_id: @project.id, location_id:)
    @mi = @mi_metal.machine_image_version.machine_image
    @mi_metal.update(enabled: true)
  end

  it "sets the latest version" do
    body = cli(%W[mi eu-central-h1/#{@mi.name} set-latest v1])
    expect(body).to eq("Machine image latest version set to v1\n")
    expect(@mi.reload.latest_version_id).to eq(@mi_metal.machine_image_version.id)
  end

  it "fails when version argument is missing" do
    expect(cli(%W[mi eu-central-h1/#{@mi.name} set-latest], status: 400)).to start_with("! Invalid number of arguments for mi set-latest subcommand")
  end
end
