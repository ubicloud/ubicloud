# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe PgGceImage do
  it "creates a PgGceImage with required fields" do
    image = described_class.create_with_id(SecureRandom.uuid,
      gcp_project_id: "test-project",
      gce_image_name: "postgres-ubuntu-2404-x64-20260218",
      pg_version: "17",
      arch: "x64")

    expect(image.gcp_project_id).to eq("test-project")
    expect(image.gce_image_name).to eq("postgres-ubuntu-2404-x64-20260218")
    expect(image.pg_version).to eq("17")
    expect(image.arch).to eq("x64")
  end

  it "enforces uniqueness on (gcp_project_id, pg_version, arch)" do
    described_class.create_with_id(SecureRandom.uuid,
      gcp_project_id: "test-project",
      gce_image_name: "image1",
      pg_version: "17",
      arch: "x64")

    expect {
      described_class.create_with_id(SecureRandom.uuid,
        gcp_project_id: "test-project",
        gce_image_name: "image2",
        pg_version: "17",
        arch: "x64")
    }.to raise_error(Sequel::Error)
  end

  it "allows different versions for the same project and arch" do
    described_class.create_with_id(SecureRandom.uuid,
      gcp_project_id: "test-project",
      gce_image_name: "postgres-17-x64",
      pg_version: "17",
      arch: "x64")

    image2 = described_class.create_with_id(SecureRandom.uuid,
      gcp_project_id: "test-project",
      gce_image_name: "postgres-18-x64",
      pg_version: "18",
      arch: "x64")

    expect(image2.pg_version).to eq("18")
  end

  it "can be looked up by find" do
    described_class.create_with_id(SecureRandom.uuid,
      gcp_project_id: "test-project",
      gce_image_name: "postgres-ubuntu-2404-arm64-20260218",
      pg_version: "17",
      arch: "arm64")

    found = described_class.find(gcp_project_id: "test-project", pg_version: "17", arch: "arm64")
    expect(found).not_to be_nil
    expect(found.gce_image_name).to eq("postgres-ubuntu-2404-arm64-20260218")
  end
end
