# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe PgGceImage do
  before { described_class.dataset.destroy }

  it "creates a PgGceImage with required fields" do
    image = described_class.create(
      gce_image_name: "postgres-ubuntu-2404-x64-20260218",
      arch: "x64",
    )

    expect(image.gce_image_name).to eq("postgres-ubuntu-2404-x64-20260218")
    expect(image.arch).to eq("x64")
  end

  it "enforces uniqueness on (arch, gce_image_name)" do
    described_class.create(
      gce_image_name: "image1",
      arch: "x64",
    )

    expect {
      described_class.create(
        gce_image_name: "image1",
        arch: "x64",
      )
    }.to raise_error(Sequel::Error)
  end

  it "allows multiple images per arch" do
    described_class.create(
      gce_image_name: "image1",
      arch: "x64",
    )

    expect {
      described_class.create(
        gce_image_name: "image2",
        arch: "x64",
      )
    }.not_to raise_error
  end

  it "can be looked up by find" do
    described_class.create(
      gce_image_name: "postgres-ubuntu-2404-arm64-20260218",
      arch: "arm64",
    )

    found = described_class.find(arch: "arm64")
    expect(found).not_to be_nil
    expect(found.gce_image_name).to eq("postgres-ubuntu-2404-arm64-20260218")
  end
end
