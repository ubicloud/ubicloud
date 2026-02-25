# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Clover, "cli mi show" do
  before do
    @project.set_ff_machine_image(true)
    @mi = MachineImage.create(
      name: "test-image",
      version: "v1",
      description: "test description",
      project_id: @project.id,
      location_id: Location::HETZNER_FSN1_ID,
      state: "available",
      s3_bucket: "test-bucket",
      s3_prefix: "images/test/",
      s3_endpoint: "https://r2.example.com",
      size_gib: 20,
      active: true
    )
    @ref = "eu-central-h1/test-image"
  end

  it "shows information for machine image" do
    result = cli(%W[mi #{@ref} show])
    expect(result).to include("id: #{@mi.ubid}")
    expect(result).to include("name: test-image")
    expect(result).to include("version: v1")
    expect(result).to include("location: eu-central-h1")
    expect(result).to include("state: available")
    expect(result).to include("size-gib: 20")
    expect(result).to include("description: test description")
    expect(result).to include("source-vm-id: ")
    expect(result).to include("created-at: #{@mi.created_at.iso8601}")
  end

  it "-f option controls which fields are shown" do
    expect(cli(%W[mi #{@ref} show -f id,name,version])).to eq <<~END
      id: #{@mi.ubid}
      name: test-image
      version: v1
    END
  end
end
