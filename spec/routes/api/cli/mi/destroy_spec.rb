# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Clover, "cli mi destroy" do
  before do
    @project.set_ff_machine_image(true)
    @mi = MachineImage.create(
      name: "test-image",
      project_id: @project.id,
      location_id: Location::HETZNER_FSN1_ID
    )
    @ver = MachineImageVersion.create(
      machine_image_id: @mi.id,
      version: 1,
      state: "available",
      size_gib: 20,
      arch: "arm64",
      s3_bucket: "test-bucket",
      s3_prefix: "images/test/",
      s3_endpoint: "https://r2.example.com"
    )
    Strand.create(id: @ver.id, prog: "MachineImage::Nexus", label: "wait", stack: [{"subject_id" => @ver.id}])
  end

  it "destroys mi directly if -f option is given" do
    expect(cli(%w[mi eu-central-h1/test-image destroy -f])).to eq "Machine image, if it exists, is now scheduled for destruction\n"
    expect(SemSnap.new(@ver.id).set?("destroy")).to be true
  end

  it "asks for confirmation if -f option is not given" do
    expect(cli(%w[mi eu-central-h1/test-image destroy], confirm_prompt: "Confirmation")).to eq <<~END
      Destroying this machine image is not recoverable.
      Enter the following to confirm destruction of the machine image: #{@mi.name}
    END
    expect(SemSnap.new(@ver.id).set?("destroy")).to be false
  end

  it "works on correct confirmation" do
    expect(cli(%w[--confirm test-image mi eu-central-h1/test-image destroy])).to eq "Machine image, if it exists, is now scheduled for destruction\n"
    expect(SemSnap.new(@ver.id).set?("destroy")).to be true
  end

  it "fails on incorrect confirmation" do
    expect(cli(%w[--confirm foo mi eu-central-h1/test-image destroy], status: 400)).to eq "! Confirmation of machine image name not successful.\n"
    expect(SemSnap.new(@ver.id).set?("destroy")).to be false
  end
end
