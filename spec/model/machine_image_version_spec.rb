# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe MachineImageVersion do
  let(:project) { Project.create(name: "test") }
  let(:location) { Location[Location::HETZNER_FSN1_ID] }

  let(:mi) {
    MachineImage.create(
      name: "test-image-v",
      project_id: project.id,
      location_id: location.id
    )
  }

  let(:miv) {
    described_class.create(
      machine_image_id: mi.id,
      version: "v1",
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
      expect(miv.reload.activated_at).to be_within(2).of(Time.now)
    end

    it "can be called multiple times, updating the timestamp" do
      miv.activate!
      first_time = miv.reload.activated_at
      sleep 0.01
      miv.activate!
      expect(miv.reload.activated_at).to be >= first_time
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

    it "returns false when state is not creating" do
      expect(miv.creating?).to be false
    end
  end

  describe "#destroying?" do
    it "returns true when state is destroying" do
      miv.update(state: "destroying")
      expect(miv.destroying?).to be true
    end

    it "returns false when state is not destroying" do
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

    it "returns false when activated but a newer version is active" do
      miv.activate!
      v2 = described_class.create(
        machine_image_id: mi.id, version: "v2", state: "available",
        size_gib: 10, s3_bucket: "b", s3_prefix: "p", s3_endpoint: "e",
        activated_at: Time.now + 100
      )
      expect(miv.active?).to be false
      v2.destroy
    end
  end

  describe "#display_location" do
    it "delegates to machine_image" do
      expect(miv.display_location).to eq(location.display_name)
    end
  end

  describe "#path" do
    it "delegates to machine_image" do
      expect(miv.path).to eq(mi.path)
    end
  end

  describe "#archive_params" do
    it "returns archive configuration hash" do
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

  describe "#before_destroy" do
    it "nullifies vm_storage_volume references and destroys cleanly" do
      miv.destroy
      expect(described_class[miv.id]).to be_nil
    end

    it "finalizes active billing records" do
      BillingRecord.create(
        project_id: project.id,
        resource_id: miv.id,
        resource_name: "test",
        billing_rate_id: BillingRate.from_resource_properties("MachineImageStorage", "standard", location.name)["id"],
        amount: 1.0
      )

      expect(miv.reload.active_billing_records).not_to be_empty
      expect(miv.active_billing_records.first).to receive(:finalize).and_call_original
      miv.destroy
    end

    it "destroys key encryption key if present" do
      kek = StorageKeyEncryptionKey.create(
        algorithm: "aes-256-gcm",
        key: Base64.encode64("test-key-32-bytes-long-enough!!!"),
        init_vector: Base64.encode64("test-iv-16bytes!"),
        auth_data: miv.ubid
      )
      miv.update(key_encryption_key_1_id: kek.id)

      miv.destroy
      expect(StorageKeyEncryptionKey[kek.id]).to be_nil
    end
  end
end
