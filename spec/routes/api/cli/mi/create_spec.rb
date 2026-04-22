# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Clover, "cli mi create" do
  let(:location_id) { Location[display_name: TEST_LOCATION].id }

  before do
    @project.set_ff_machine_image(true)
    MachineImageStore.create(project_id: @project.id, location_id:, provider: "r2", region: "auto",
      endpoint: "https://r2.cloudflare.com/", bucket: "test-bucket", access_key: "ak", secret_key: "sk")
    @vm = create_archive_ready_vm(project_id: @project.id, location_id:)
  end

  it "creates a machine image with --vm only" do
    body = cli(%W[mi eu-central-h1/test-mi create -v #{@vm.ubid}])
    mi = MachineImage[name: "test-mi"]
    expect(mi).not_to be_nil
    expect(mi.versions.count).to eq(1)
    expect(body).to eq("Machine image created with id: #{mi.ubid}\n")
  end

  it "creates a machine image with --version and --destroy-source" do
    cli(%W[mi eu-central-h1/test-mi create -v #{@vm.ubid} -V v1.0 -d])
    mi = MachineImage[name: "test-mi"]
    expect(mi).not_to be_nil
    miv = mi.versions_dataset.first(version: "v1.0")
    expect(miv).not_to be_nil
    expect(miv.strand.stack.first["destroy_source_after"]).to be true
  end

  it "fails if --vm is missing" do
    expect(cli(%w[mi eu-central-h1/test-mi create], status: 400)).to start_with("! --vm option is required")
  end
end
