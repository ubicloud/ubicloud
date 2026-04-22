# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Clover, "cli mi create-version" do
  let(:location_id) { Location[display_name: TEST_LOCATION].id }

  before do
    @project.set_ff_machine_image(true)
    @mi_metal = create_machine_image_version_metal(project_id: @project.id, location_id:)
    @mi = @mi_metal.machine_image_version.machine_image
    @vm = create_archive_ready_vm(project_id: @project.id, location_id:)
  end

  it "creates a version with provided label" do
    body = cli(%W[mi eu-central-h1/#{@mi.name} create-version -v #{@vm.ubid} -V v2 -d])
    expect(body).to match(/Machine image version created with id: mv/)
    miv = @mi.versions_dataset.first(version: "v2")
    expect(miv).not_to be_nil
    expect(miv.strand.stack.first["destroy_source_after"]).to be true
  end

  it "uses a timestamp when --version is omitted" do
    cli(%W[mi eu-central-h1/#{@mi.name} create-version -v #{@vm.ubid}])
    miv = @mi.versions_dataset.exclude(version: "v1").first
    expect(miv.version).to match(/\A\d{14}\z/)
    expect(miv.strand.stack.first["destroy_source_after"]).to be false
  end

  it "fails if --vm is missing" do
    expect(cli(%W[mi eu-central-h1/#{@mi.name} create-version], status: 400)).to start_with("! --vm option is required")
  end
end
