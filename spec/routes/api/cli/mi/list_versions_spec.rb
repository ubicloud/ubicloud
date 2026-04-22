# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Clover, "cli mi list-versions" do
  let(:location_id) { Location[display_name: TEST_LOCATION].id }

  before do
    @project.set_ff_machine_image(true)
    @mi_metal = create_machine_image_version_metal(project_id: @project.id, location_id:)
    @mi = @mi_metal.machine_image_version.machine_image
  end

  it "lists versions without headers when -N is given" do
    body = cli(%W[mi eu-central-h1/#{@mi.name} list-versions -N])
    expect(body).to include("v1", @mi_metal.machine_image_version.ubid, "ready")
    expect(body).not_to include("version  id")
  end

  it "shows headers by default" do
    body = cli(%W[mi eu-central-h1/#{@mi.name} list-versions])
    expect(body).to include("version", "id", "state")
  end

  it "restricts fields with -f" do
    body = cli(%W[mi eu-central-h1/#{@mi.name} list-versions -N -f version])
    expect(body).to eq("v1\n")
  end
end
