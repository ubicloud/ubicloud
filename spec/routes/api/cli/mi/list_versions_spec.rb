# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Clover, "cli mi list-versions" do
  let(:location_id) { Location[display_name: TEST_LOCATION].id }

  before do
    @project.set_ff_machine_image(true)
    @mi_metal = create_machine_image_version_metal(project_id: @project.id, location_id:)
    @mi = @mi_metal.machine_image_version.machine_image
    @miv = @mi_metal.machine_image_version
  end

  it "lists versions without headers when -N is given" do
    body = cli(%W[mi eu-central-h1/#{@mi.name} list-versions -N])
    expect(body).to eq("v1  #{@miv.ubid}  ready  5120  1024  #{@miv.created_at.iso8601}\n")
  end

  it "shows headers by default" do
    body = cli(%W[mi eu-central-h1/#{@mi.name} list-versions])
    expect(body).to eq("version  id                          state  actual-size-mib  archive-size-mib  created-at               \nv1       #{@miv.ubid}  ready  5120             1024              #{@miv.created_at.iso8601}\n")
  end

  it "restricts fields with -f" do
    body = cli(%W[mi eu-central-h1/#{@mi.name} list-versions -N -f version])
    expect(body).to eq("v1\n")
  end
end
