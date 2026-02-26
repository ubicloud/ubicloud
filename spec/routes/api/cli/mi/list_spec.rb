# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Clover, "cli mi list" do
  before do
    @project.set_ff_machine_image(true)
    mi = MachineImage.create(
      name: "test-image",
      project_id: @project.id,
      location_id: Location::HETZNER_FSN1_ID
    )
    @mi = mi
    ver = MachineImageVersion.create(
      machine_image_id: mi.id,
      version: 1,
      state: "available",
      size_gib: 20,
      arch: "arm64",
      s3_bucket: "test-bucket",
      s3_prefix: "images/test/",
      s3_endpoint: "https://r2.example.com"
    )
    ver.activate!
  end

  it "shows list of machine images" do
    expect(cli(%w[mi list -N])).to eq "eu-central-h1  test-image  1  available  20  #{@mi.ubid}\n"
  end

  it "-f id option includes image ubid" do
    expect(cli(%w[mi list -Nfid])).to eq "#{@mi.ubid}\n"
  end

  it "-f name option includes image name" do
    expect(cli(%w[mi list -Nfname])).to eq "test-image\n"
  end

  it "-f version option includes image version" do
    expect(cli(%w[mi list -Nfversion])).to eq "1\n"
  end

  it "-f location option includes image location" do
    expect(cli(%w[mi list -Nflocation])).to eq "eu-central-h1\n"
  end

  it "-l option filters to specific location" do
    expect(cli(%w[mi list -Nleu-central-h1])).to eq "eu-central-h1  test-image  1  available  20  #{@mi.ubid}\n"
    expect(cli(%w[mi list -Nleu-north-h1])).to eq "\n"
  end

  it "headers are shown by default" do
    id_headr = "id" + " " * 24
    expect(cli(%w[mi list])).to eq <<~END
      location       name        version  state      size-gib  #{id_headr}
      eu-central-h1  test-image  1        available  20        #{@mi.ubid}
    END
  end
end
