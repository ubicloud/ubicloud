# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe MachineImageVersion do
  let(:project) { Project.create(name: "test") }
  let(:location_id) { Location::HETZNER_FSN1_ID }

  let(:mi) {
    MachineImage.create(name: "test-image", project_id: project.id, location_id: location_id)
  }

  let(:miv) {
    described_class.create(
      machine_image_id: mi.id,
      version: "20260101-1",
      state: "available",
      size_gib: 10,
      s3_bucket: "test-bucket",
      s3_prefix: "test-prefix",
      s3_endpoint: "https://s3.example.com"
    )
  }

  describe "#activate!" do
    it "sets activated_at to current time" do
      expect(miv.activated_at).to be_nil
      miv.activate!
      expect(miv.reload.activated_at).to be_within(5).of(Time.now)
    end

    it "overwrites a previously set activated_at" do
      miv.update(activated_at: Time.now - 86400)
      miv.activate!
      expect(miv.reload.activated_at).to be_within(5).of(Time.now)
    end
  end

  describe "#available?" do
    it "returns true when state is available" do
      expect(miv.available?).to be true
    end

    it "returns false when state is not available" do
      miv.update(state: "creating")
      expect(miv.available?).to be false
    end
  end

  describe "#creating?" do
    it "returns true when state is creating" do
      miv.update(state: "creating")
      expect(miv.creating?).to be true
    end

    it "returns false when state is available" do
      expect(miv.creating?).to be false
    end
  end

  describe "#destroying?" do
    it "returns true when state is destroying" do
      miv.update(state: "destroying")
      expect(miv.destroying?).to be true
    end

    it "returns false when state is available" do
      expect(miv.destroying?).to be false
    end
  end

  describe "#active?" do
    it "returns false when not activated" do
      expect(miv.active?).to be false
    end

    it "returns true when activated and is the active version" do
      miv.activate!
      expect(miv.reload.active?).to be true
    end

    it "returns false when activated but another version is the active one" do
      miv.activate!
      described_class.create(
        machine_image_id: mi.id,
        version: "20260102-1",
        state: "available",
        size_gib: 10,
        s3_bucket: "test-bucket",
        s3_prefix: "test-prefix",
        s3_endpoint: "https://s3.example.com",
        activated_at: Time.now + 3600
      )
      expect(miv.reload.active?).to be false
    end
  end

  describe "#display_location" do
    it "delegates to machine_image" do
      expect(miv.display_location).to eq("eu-central-h1")
    end
  end

  describe "#path" do
    it "delegates to machine_image" do
      expect(miv.path).to eq(mi.path)
    end
  end

  describe "#archive_params" do
    it "returns expected hash" do
      params = miv.archive_params
      expect(params["type"]).to eq("archive")
      expect(params["archive_bucket"]).to eq("test-bucket")
      expect(params["archive_prefix"]).to eq("test-prefix")
      expect(params["archive_endpoint"]).to eq("https://s3.example.com")
      expect(params["compression"]).to eq("zstd")
      expect(params["encrypted"]).to be true
      expect(params["has_session_token"]).to be true
    end
  end

  describe "associations" do
    it "belongs to machine_image" do
      expect(miv.machine_image.id).to eq(mi.id)
    end
  end

  describe "ResourceMethods" do
    it "generates a UBID" do
      expect(miv.ubid).to start_with("mv")
    end
  end

  describe "state values" do
    it "supports all expected states" do
      %w[creating available failed destroying].each do |state|
        miv.update(state: state)
        expect(miv.reload.state).to eq(state)
      end
    end
  end
end
