# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe MachineImageVersion do
  let(:project) { Project.create(name: "test") }
  let(:location_id) { Location::HETZNER_FSN1_ID }

  let(:mi) {
    MachineImage.create(
      name: "test-image",
      description: "test desc",
      project_id: project.id,
      location_id: location_id
    )
  }

  let(:miv) {
    described_class.create(
      machine_image_id: mi.id,
      version: "20260303-1",
      state: "available",
      size_gib: 20,
      s3_bucket: "test-bucket",
      s3_prefix: "images/test/",
      s3_endpoint: "https://r2.example.com"
    )
  }

  describe "#activate!" do
    it "sets activated_at to current time" do
      expect(miv.activated_at).to be_nil
      miv.activate!
      miv.reload
      expect(miv.activated_at).to be_within(2).of(Time.now)
    end

    it "updates activated_at when called again" do
      miv.activate!
      first_time = miv.reload.activated_at
      sleep 0.01
      miv.activate!
      miv.reload
      expect(miv.activated_at).to be >= first_time
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
    it "returns true when activated and is the active version" do
      miv.activate!
      expect(miv.active?).to be true
    end

    it "returns false when not activated" do
      expect(miv.active?).to be false
    end

    it "returns false when activated but not the active version" do
      miv.update(activated_at: Time.now - 7200)
      described_class.create(
        machine_image_id: mi.id, version: "20260303-2", state: "available",
        size_gib: 20, s3_bucket: "b", s3_prefix: "p/", s3_endpoint: "https://r2.example.com",
        activated_at: Time.now
      )
      expect(miv.active?).to be false
    end
  end

  describe "#display_location" do
    it "delegates to machine_image" do
      loc = Location[location_id]
      expect(miv.display_location).to eq(loc.display_name)
    end
  end

  describe "#path" do
    it "delegates to machine_image" do
      expect(miv.path).to eq(mi.path)
    end
  end

  describe "associations" do
    it "belongs to a machine_image" do
      expect(miv.machine_image.id).to eq(mi.id)
    end

    it "can belong to a vm" do
      expect(miv.vm).to be_nil
    end
  end

  describe "state values" do
    it "supports creating state" do
      v = described_class.create(
        machine_image_id: mi.id, version: "v-creating", state: "creating",
        size_gib: 10, s3_bucket: "b", s3_prefix: "p/", s3_endpoint: "https://r2.example.com"
      )
      expect(v.state).to eq("creating")
    end

    it "supports failed state" do
      v = described_class.create(
        machine_image_id: mi.id, version: "v-failed", state: "failed",
        size_gib: 10, s3_bucket: "b", s3_prefix: "p/", s3_endpoint: "https://r2.example.com"
      )
      expect(v.state).to eq("failed")
    end

    it "supports destroying state" do
      v = described_class.create(
        machine_image_id: mi.id, version: "v-destroying", state: "destroying",
        size_gib: 10, s3_bucket: "b", s3_prefix: "p/", s3_endpoint: "https://r2.example.com"
      )
      expect(v.state).to eq("destroying")
    end
  end

  describe "#archive_params" do
    it "returns the expected hash structure" do
      miv.update(s3_bucket: "my-bucket", s3_prefix: "img/v1/", s3_endpoint: "https://r2.example.com")
      params = miv.archive_params
      expect(params["type"]).to eq("archive")
      expect(params["archive_bucket"]).to eq("my-bucket")
      expect(params["archive_prefix"]).to eq("img/v1/")
      expect(params["archive_endpoint"]).to eq("https://r2.example.com")
      expect(params["compression"]).to eq("zstd")
      expect(params["encrypted"]).to be true
      expect(params["has_session_token"]).to be true
    end
  end
end
