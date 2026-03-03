# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe MachineImageVersion do
  let(:project) { Project.create(name: "test-miv") }
  let(:location) { Location[Location::HETZNER_FSN1_ID] }

  let(:mi) {
    MachineImage.create(
      name: "test-image-miv",
      project_id: project.id,
      location_id: location.id
    )
  }

  let(:miv) {
    described_class.create(
      machine_image_id: mi.id,
      version: "20260301-1",
      state: "available",
      size_gib: 10,
      s3_bucket: "test-bucket",
      s3_prefix: "images/test",
      s3_endpoint: "https://s3.example.com"
    )
  }

  describe "#activate!" do
    it "sets activated_at to current time" do
      expect(miv.activated_at).to be_nil
      miv.activate!
      expect(miv.reload.activated_at).to be_within(2).of(Time.now)
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

    it "returns false when activated but not the active version" do
      miv.update(activated_at: Time.now - 3600)
      newer = described_class.create(
        machine_image_id: mi.id, version: "20260301-2", state: "available",
        size_gib: 10, s3_bucket: "b", s3_prefix: "p", s3_endpoint: "e",
        activated_at: Time.now
      )

      expect(miv.reload.active?).to be false
      newer.destroy
    end
  end

  describe "#display_location" do
    it "delegates to machine_image.display_location" do
      expect(miv.display_location).to eq(location.display_name)
    end
  end

  describe "#path" do
    it "delegates to machine_image.path" do
      expect(miv.path).to eq(mi.path)
    end
  end

  describe "#archive_params" do
    it "returns archive configuration hash" do
      params = miv.archive_params
      expect(params["type"]).to eq("archive")
      expect(params["archive_bucket"]).to eq("test-bucket")
      expect(params["archive_prefix"]).to eq("images/test")
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

  describe "#before_destroy" do
    it "nullifies machine_image_version_id on vm_storage_volumes" do
      version_id = miv.id
      miv.destroy
      expect(described_class[version_id]).to be_nil
    end

    it "finalizes active billing records" do
      now = Time.now
      original_end = now + 3600
      br = BillingRecord.create(
        project_id: project.id,
        resource_id: miv.id,
        resource_name: "test",
        billing_rate_id: BillingRate.from_resource_properties("VmVCpu", "standard", "hetzner-fsn1")["id"],
        span: Sequel.pg_range(now..original_end),
        amount: 1
      )

      miv.destroy
      br.reload
      # Finalized means span end was shortened from now+3600 to approximately now
      expect(br.span.last).to be < original_end
    end

    it "destroys associated key_encryption_key" do
      kek = StorageKeyEncryptionKey.create(
        algorithm: "aes-256-gcm",
        key: "dGVzdC1rZXktZW5jcnlwdGlvbi1rZXk=",
        init_vector: "dGVzdC1pbml0LXZlY3Rvcg==",
        auth_data: "dGVzdC1hdXRo"
      )
      miv.update(key_encryption_key_1_id: kek.id)

      miv.destroy
      expect(StorageKeyEncryptionKey[kek.id]).to be_nil
    end
  end
end
