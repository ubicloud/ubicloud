# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Clover, "cli mi destroy-version" do
  let(:location_id) { Location[display_name: TEST_LOCATION].id }
  let(:extra_metal) { MachineImageVersionMetal[@mi.versions_dataset.first(version: "v2").id] }

  before do
    @project.set_ff_machine_image(true)
    @mi_metal = create_machine_image_version_metal(project_id: @project.id, location_id:)
    @mi = @mi_metal.machine_image_version.machine_image
    extra = MachineImageVersion.create(machine_image_id: @mi.id, version: "v2")
    MachineImageVersionMetal.create_with_id(extra, archive_kek_id: @mi_metal.archive_kek_id,
      store_id: @mi_metal.store_id, store_prefix: "p2", enabled: true, archive_size_mib: 10)
    @mi.update(latest_version_id: @mi_metal.machine_image_version.id)
  end

  it "schedules version destruction with -f" do
    body = cli(%W[mi eu-central-h1/#{@mi.name} destroy-version -V v2 -f])
    expect(body).to eq("Machine image version v2 is now scheduled for destruction\n")
    expect(Strand[extra_metal.id].prog).to eq("MachineImage::DestroyVersionMetal")
  end

  it "asks for confirmation when -f is not given" do
    body = cli(%W[mi eu-central-h1/#{@mi.name} destroy-version -V v2], confirm_prompt: "Confirmation")
    expect(body).to eq <<~END
      Destroying this machine image version is not recoverable.
      Enter the following to confirm destruction of the machine image version: v2
    END
  end

  it "works on correct confirmation" do
    body = cli(%W[--confirm v2 mi eu-central-h1/#{@mi.name} destroy-version -V v2])
    expect(body).to eq("Machine image version v2 is now scheduled for destruction\n")
    expect(Strand[extra_metal.id].prog).to eq("MachineImage::DestroyVersionMetal")
  end

  it "fails on incorrect confirmation" do
    body = cli(%W[--confirm wrong mi eu-central-h1/#{@mi.name} destroy-version -V v2], status: 400)
    expect(body).to eq "! Confirmation of machine image version label not successful.\n"
  end

  it "fails if --version is missing" do
    expect(cli(%W[mi eu-central-h1/#{@mi.name} destroy-version], status: 400)).to start_with("! --version option is required")
  end
end
