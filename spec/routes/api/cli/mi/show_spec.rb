# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Clover, "cli mi show" do
  let(:location_id) { Location[display_name: TEST_LOCATION].id }

  before do
    @project.set_ff_machine_image(true)
    @mi_metal = create_machine_image_version_metal(project_id: @project.id, location_id:)
    @mi = @mi_metal.machine_image_version.machine_image
    @mi.update(latest_version_id: @mi_metal.machine_image_version.id)
  end

  it "shows machine image details" do
    body = cli(%W[mi eu-central-h1/#{@mi.name} show])
    expect(body).to include("name: #{@mi.name}")
    expect(body).to include("arch: x64")
    expect(body).to include("version 1:")
    expect(body).to include("enabled: true")
  end

  it "restricts fields with -f" do
    body = cli(%W[mi eu-central-h1/#{@mi.name} show -f id,name])
    expect(body).to eq("id: #{@mi.ubid}\nname: #{@mi.name}\n")
  end

  it "supports lookup by ubid" do
    body = cli(%W[mi #{@mi.ubid} show -f name])
    expect(body).to eq("name: #{@mi.name}\n")
  end

  it "rejects invalid fields" do
    expect(cli(%W[mi eu-central-h1/#{@mi.name} show -f bogus], status: 400)).to start_with(
      "! Invalid field(s) given in mi show -f option",
    )
  end
end
