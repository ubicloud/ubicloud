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
      version: "20260101-1",
      state: "available",
      size_gib: 10,
      s3_bucket: "test-bucket",
      s3_prefix: "test-prefix",
      s3_endpoint: "https://s3.example.com"
    )
  }

  def create_version(attrs = {})
    described_class.create({
      machine_image_id: mi.id,
      version: "v1",
      state: "available",
      size_gib: 10,
      s3_bucket: "test-bucket",
      s3_prefix: "test-prefix",
      s3_endpoint: "https://s3.example.com"
    }.merge(attrs))
  end

  describe "#activate!" do
    it "sets activated_at to current time" do
      expect(miv.activated_at).to be_nil
      miv.activate!
      expect(miv.reload.activated_at).not_to be_nil
    end

    it "updates activated_at when called again" do
      miv.activate!
      first = miv.reload.activated_at
      sleep 0.01
      miv.activate!
      expect(miv.reload.activated_at).to be >= first
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

    it "returns false when a newer version is active" do
      miv.activate!
      create_version(version: "v2", activated_at: Time.now + 100)
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

  describe "associations" do
    it "belongs to a machine_image" do
      expect(miv.machine_image.id).to eq(mi.id)
    end

    it "can belong to a vm" do
      expect(miv.vm).to be_nil
    end
  end

  describe "#before_destroy" do
    it "finalizes active billing records and cleans up KEK" do
      kek = StorageKeyEncryptionKey.create(
        algorithm: "aes-256-gcm",
        key: "a" * 64,
        init_vector: "b" * 32,
        auth_data: "c" * 32
      )
      miv.update(key_encryption_key_1_id: kek.id)

      miv.destroy
      expect(described_class[miv.id]).to be_nil
      expect(StorageKeyEncryptionKey[kek.id]).to be_nil
    end

    it "nullifies vm_storage_volume references" do
      miv.destroy
      expect(described_class[miv.id]).to be_nil
    end
  end

  it "generates a ubid" do
    expect(miv.ubid).to start_with("mv")
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
