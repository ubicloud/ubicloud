# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Clover, "cli mi show" do
  before do
    @project.set_ff_machine_image(true)
    mi = MachineImage.create(
      name: "test-image",
      description: "test description",
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
    @ref = "eu-central-h1/test-image"
  end

  it "shows information for machine image" do
    result = cli(%W[mi #{@ref} show])
    expect(result).to include("id: #{@mi.ubid}")
    expect(result).to include("name: test-image")
    expect(result).to include("version: 1")
    expect(result).to include("location: eu-central-h1")
    expect(result).to include("state: available")
    expect(result).to include("size-gib: 20")
    expect(result).to include("arch: arm64")
    expect(result).to include("description: test description")
    expect(result).to include("created-at: #{@mi.created_at.iso8601}")
  end

  it "-f option controls which fields are shown" do
    expect(cli(%W[mi #{@ref} show -f id,name,version])).to eq <<~END
      id: #{@mi.ubid}
      name: test-image
      version: 1
    END
  end
end
