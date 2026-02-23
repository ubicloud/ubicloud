# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Clover, "cli mi show" do
  before do
    @mi = MachineImage.create(
      name: "test-mi",
      description: "test desc",
      project_id: @project.id,
      location_id: Location::HETZNER_FSN1_ID,
      state: "available",
      s3_bucket: "test-bucket",
      s3_prefix: "images/test/",
      s3_endpoint: "https://r2.example.com",
      size_gib: 20
    )
  end

  it "shows machine image details" do
    body = cli(%w[mi eu-central-h1/test-mi show])
    expect(body).to include("name: test-mi")
    expect(body).to include("state: available")
  end

  it "shows machine image with specific fields" do
    body = cli(%w[mi eu-central-h1/test-mi show -f id,name,state])
    expect(body).to include("name: test-mi")
    expect(body).to include("state: available")
    expect(body).not_to include("description:")
  end

  it "fails with invalid field" do
    cli(%w[mi eu-central-h1/test-mi show -f bad], status: 400)
  end
end
