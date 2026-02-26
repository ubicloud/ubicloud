# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe PgGceImage do
  it "creates a PgGceImage with required fields" do
    image = described_class.create_with_id(SecureRandom.uuid,
      gcp_project_id: "test-project",
      gce_image_name: "postgres-ubuntu-2404-x64-20260218",
      pg_version: "99",
      arch: "x64")

    expect(image.gcp_project_id).to eq("test-project")
    expect(image.gce_image_name).to eq("postgres-ubuntu-2404-x64-20260218")
    expect(image.pg_version).to eq("99")
    expect(image.arch).to eq("x64")
  end

  it "enforces uniqueness on (pg_version, arch)" do
    described_class.create_with_id(SecureRandom.uuid,
      gcp_project_id: "project-a",
      gce_image_name: "image1",
      pg_version: "98",
      arch: "x64")

    expect {
      described_class.create_with_id(SecureRandom.uuid,
        gcp_project_id: "project-b",
        gce_image_name: "image2",
        pg_version: "98",
        arch: "x64")
    }.to raise_error(Sequel::Error)
  end

  it "allows different versions for the same arch" do
    described_class.create_with_id(SecureRandom.uuid,
      gcp_project_id: "test-project",
      gce_image_name: "postgres-97-x64",
      pg_version: "97",
      arch: "x64")

    image2 = described_class.create_with_id(SecureRandom.uuid,
      gcp_project_id: "test-project",
      gce_image_name: "postgres-96-x64",
      pg_version: "96",
      arch: "x64")

    expect(image2.pg_version).to eq("96")
  end

  it "can be looked up by find" do
    described_class.create_with_id(SecureRandom.uuid,
      gcp_project_id: "test-project",
      gce_image_name: "postgres-ubuntu-2404-arm64-20260218",
      pg_version: "95",
      arch: "arm64")

    found = described_class.find(pg_version: "95", arch: "arm64")
    expect(found).not_to be_nil
    expect(found.gce_image_name).to eq("postgres-ubuntu-2404-arm64-20260218")
  end
end
