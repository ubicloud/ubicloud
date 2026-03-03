# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe MachineImageVersion do
  let(:project) { Project.create(name: "test") }
  let(:location_id) { Location::HETZNER_FSN1_ID }

  let(:mi) {
    MachineImage.create(
      name: "test-image",
      project_id: project.id,
      location_id: location_id
    )
  }

  let(:miv) {
    described_class.create(
      machine_image_id: mi.id,
      version: "20260301-1",
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
      expect(miv.reload.activated_at).not_to be_nil
      expect(miv.activated_at).to be_within(5).of(Time.now)
    end

    it "can be called multiple times, updating the timestamp" do
      miv.activate!
      first_time = miv.reload.activated_at
      sleep 0.01
      miv.activate!
      expect(miv.reload.activated_at).to be >= first_time
    end
  end

  describe "#display_location" do
    it "delegates to machine_image.display_location" do
      expect(miv.display_location).to eq(mi.display_location)
    end
  end

  describe "#path" do
    it "delegates to machine_image.path" do
      expect(miv.path).to eq(mi.path)
    end
  end

  describe "state predicates" do
    it "#available? returns true when state is available" do
      expect(miv.available?).to be true
      miv.update(state: "creating")
      expect(miv.reload.available?).to be false
    end

    it "#creating? returns true when state is creating" do
      miv.update(state: "creating")
      expect(miv.reload.creating?).to be true
      expect(miv.available?).to be false
    end

    it "#destroying? returns true when state is destroying" do
      miv.update(state: "destroying")
      expect(miv.reload.destroying?).to be true
      expect(miv.available?).to be false
    end
  end

  describe "#active?" do
    it "returns true when version is activated and is the active version" do
      miv.activate!
      expect(miv.reload.active?).to be true
    end

    it "returns false when not activated" do
      expect(miv.active?).to be false
    end

    it "returns false when activated but not the active version" do
      miv.activate!
      described_class.create(
        machine_image_id: mi.id, version: "v2", state: "available",
        size_gib: 10, s3_bucket: "b", s3_prefix: "p", s3_endpoint: "e",
        activated_at: Time.now + 3600
      )
      expect(miv.reload.active?).to be false
    end
  end

  describe "#archive_params" do
    it "returns a hash with archive configuration" do
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

  describe "#before_destroy" do
    it "nullifies vm_storage_volume references" do
      expect(VmStorageVolume).to receive(:where).with(machine_image_version_id: miv.id).and_return(
        instance_double(Sequel::Dataset, update: 1)
      )
      miv.destroy
    end

    it "finalizes active billing records" do
      original_end = Time.now + 3600
      br = BillingRecord.create(
        project_id: project.id,
        resource_id: miv.id, resource_name: "test",
        billing_rate_id: BillingRate.from_resource_properties("VmVCpu", "standard", "hetzner-fsn1")["id"],
        amount: 1,
        span: Sequel.pg_range(Time.now..original_end)
      )
      miv.destroy
      br.reload
      expect(br.span.end).to be < original_end
    end

    it "destroys key_encryption_key_1 if present" do
      kek = StorageKeyEncryptionKey.create(
        algorithm: "aes-256-gcm", key: "test-key-data-for-encryption-key",
        init_vector: "test-iv-data1234", auth_data: "test-auth"
      )
      miv.update(key_encryption_key_1_id: kek.id)
      miv.destroy
      expect(StorageKeyEncryptionKey[kek.id]).to be_nil
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

  describe "ResourceMethods" do
    it "generates a UBID" do
      expect(miv.ubid).to start_with("mv")
    end
  end

  describe "SemaphoreMethods" do
    it "has destroy semaphore" do
      expect(miv.respond_to?(:incr_destroy)).to be true
    end
  end
end
