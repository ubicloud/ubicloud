# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe MachineImageVersion do
  let(:project) { Project.create(name: "test-project") }
  let(:location) { Location[Location::HETZNER_FSN1_ID] }

  let(:mi) {
    MachineImage.create(
      name: "test-image",
      description: "A test image",
      project_id: project.id,
      location_id: location.id
    )
  }

  let(:version) {
    described_class.create(
      machine_image_id: mi.id,
      version: "v1",
      state: "creating",
      size_gib: 20,
      s3_bucket: "test-bucket",
      s3_prefix: "images/test/",
      s3_endpoint: "https://r2.example.com"
    )
  }

  describe "#activate!" do
    it "sets activated_at to current time" do
      expect(version.activated_at).to be_nil
      version.activate!
      expect(version.reload.activated_at).to be_within(5).of(Time.now)
    end
  end

  describe "#available?" do
    it "returns true when state is available" do
      version.update(state: "available")
      expect(version.available?).to be true
    end

    it "returns false when state is not available" do
      expect(version.available?).to be false
    end
  end

  describe "#creating?" do
    it "returns true when state is creating" do
      expect(version.creating?).to be true
    end

    it "returns false when state is not creating" do
      version.update(state: "available")
      expect(version.creating?).to be false
    end
  end

  describe "#destroying?" do
    it "returns true when state is destroying" do
      version.update(state: "destroying")
      expect(version.destroying?).to be true
    end

    it "returns false when state is not destroying" do
      expect(version.destroying?).to be false
    end
  end

  describe "#active?" do
    it "returns true when activated and is the active version of the image" do
      version.activate!
      expect(version.active?).to be true
    end

    it "returns false when not activated" do
      expect(version.active?).to be false
    end

    it "returns false when activated but not the active version" do
      version.update(activated_at: Time.now - 100)
      _v2 = described_class.create(
        machine_image_id: mi.id,
        version: "v2",
        state: "available",
        size_gib: 20,
        s3_bucket: "test-bucket",
        s3_prefix: "images/test/",
        s3_endpoint: "https://r2.example.com",
        activated_at: Time.now
      )
      expect(version.active?).to be false
    end
  end

  describe "#display_location" do
    it "delegates to machine_image.display_location" do
      expect(version.display_location).to eq(location.display_name)
    end
  end

  describe "#path" do
    it "delegates to machine_image.path" do
      expect(version.path).to eq(mi.path)
    end
  end

  describe "#archive_params" do
    it "returns archive configuration hash" do
      params = version.archive_params
      expect(params["type"]).to eq("archive")
      expect(params["archive_bucket"]).to eq("test-bucket")
      expect(params["archive_prefix"]).to eq("images/test/")
      expect(params["archive_endpoint"]).to eq("https://r2.example.com")
      expect(params["compression"]).to eq("zstd")
      expect(params["encrypted"]).to be true
      expect(params["has_session_token"]).to be true
    end
  end

  describe "associations" do
    it "belongs to a machine_image" do
      expect(version.machine_image).to eq(mi)
    end
  end

  describe "ResourceMethods" do
    it "generates a UBID" do
      expect(version.ubid).to start_with("mv")
    end
  end

  describe "state values" do
    it "supports all expected states" do
      %w[creating available failed destroying].each do |state|
        version.update(state: state)
        expect(version.reload.state).to eq(state)
      end
    end
  end
end
