# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe MachineImage do
  let(:project_id) { Project.create(name: "test").id }

  let(:mi) {
    described_class.create(
      name: "test-image",
      description: "test machine image",
      project_id:,
      location_id: Location::HETZNER_FSN1_ID,
      state: "available",
      s3_bucket: "test-bucket",
      s3_prefix: "images/test/",
      s3_endpoint: "https://r2.example.com",
      size_gib: 20
    )
  }

  it "has a valid UBID" do
    expect(mi.ubid).to start_with("m1")
  end

  it "has a path" do
    expect(mi.path).to eq("/location/eu-central-h1/machine-image/test-image")
  end

  it "has a display_location" do
    expect(mi.display_location).to eq("eu-central-h1")
  end

  it "has project association" do
    expect(mi.project).to be_a(Project)
    expect(mi.project.id).to eq(project_id)
  end

  it "has location association" do
    expect(mi.location).to be_a(Location)
  end

  it "is listed in project.machine_images" do
    expect(mi.project.machine_images).to include(mi)
  end

  describe ".for_project" do
    let(:other_project_id) { Project.create(name: "other").id }

    let(:other_private_mi) {
      described_class.create(
        name: "other-private", project_id: other_project_id,
        location_id: Location::HETZNER_FSN1_ID, state: "available",
        s3_bucket: "b", s3_prefix: "p/", s3_endpoint: "https://r2.example.com", size_gib: 10
      )
    }

    let(:other_public_mi) {
      described_class.create(
        name: "other-public", project_id: other_project_id,
        location_id: Location::HETZNER_FSN1_ID, state: "available", visible: true,
        s3_bucket: "b", s3_prefix: "p/", s3_endpoint: "https://r2.example.com", size_gib: 10
      )
    }

    it "returns images owned by the project" do
      mi # ensure created
      other_private_mi
      result = described_class.for_project(project_id).all
      expect(result).to include(mi)
      expect(result).not_to include(other_private_mi)
    end

    it "returns public images from other projects" do
      mi
      other_public_mi
      result = described_class.for_project(project_id).all
      expect(result).to include(mi)
      expect(result).to include(other_public_mi)
    end

    it "does not return private images from other projects" do
      other_private_mi
      result = described_class.for_project(project_id).all
      expect(result).not_to include(other_private_mi)
    end
  end

  it "returns encrypted?" do
    expect(mi.encrypted?).to be true
    mi.update(encrypted: false)
    expect(mi.reload.encrypted?).to be false
  end

  it "returns archive_params" do
    params = mi.archive_params
    expect(params["type"]).to eq("archive")
    expect(params["archive_bucket"]).to eq("test-bucket")
    expect(params["archive_prefix"]).to eq("images/test/")
    expect(params["archive_endpoint"]).to eq("https://r2.example.com")
    expect(params["compression"]).to eq("zstd")
    expect(params["encrypted"]).to be true
  end

  describe "state predicates" do
    it "returns true for available?" do
      expect(mi.available?).to be true
      expect(mi.creating?).to be false
    end

    it "returns true for creating?" do
      mi.update(state: "creating")
      expect(mi.creating?).to be true
      expect(mi.available?).to be false
    end

    it "returns true for decommissioned?" do
      mi.update(state: "decommissioned")
      expect(mi.decommissioned?).to be true
    end

    it "returns true for verifying?" do
      mi.update(state: "verifying")
      expect(mi.verifying?).to be true
    end

    it "returns true for destroying?" do
      mi.update(state: "destroying")
      expect(mi.destroying?).to be true
    end
  end
end
