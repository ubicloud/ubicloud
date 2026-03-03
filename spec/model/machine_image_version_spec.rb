# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe MachineImageVersion do
  let(:project) { Project.create(name: "test") }

  let(:mi) {
    MachineImage.create(
      name: "test-image",
      project_id: project.id,
      location_id: Location::HETZNER_FSN1_ID
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
    end

    it "updates an already-activated version" do
      miv.activate!
      old_time = miv.reload.activated_at
      sleep 0.01
      miv.activate!
      expect(miv.reload.activated_at).to be >= old_time
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
      miv.activate!
      described_class.create(
        machine_image_id: mi.id, version: "20260301-2", state: "available",
        size_gib: 10, s3_bucket: "b", s3_prefix: "p", s3_endpoint: "e",
        activated_at: Time.now + 1
      )
      expect(miv.active?).to be false
    end
  end

  describe "#display_location" do
    it "delegates to machine_image" do
      expect(miv.display_location).to eq(mi.display_location)
    end
  end

  describe "#path" do
    it "delegates to machine_image" do
      expect(miv.path).to eq(mi.path)
    end
  end

  describe "#archive_params" do
    it "returns the expected archive configuration" do
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
    it "belongs to a machine_image" do
      expect(miv.machine_image.id).to eq(mi.id)
    end

    it "can have an associated vm" do
      vm = create_vm(project_id: project.id)
      miv.update(vm_id: vm.id)
      expect(miv.reload.vm.id).to eq(vm.id)
    end
  end

  it "generates a ubid" do
    expect(miv.ubid).not_to be_nil
    expect(miv.ubid).to start_with("mv")
  end

  describe "#before_destroy" do
    it "nullifies vm_storage_volume references" do
      vm = create_vm(project_id: project.id)
      vol = VmStorageVolume.create(
        vm_id: vm.id, boot: true, size_gib: 10,
        disk_index: 0, machine_image_version_id: miv.id
      )
      miv.destroy
      expect(vol.reload.machine_image_version_id).to be_nil
    end

    it "finalizes active billing records" do
      BillingRecord.create(
        project_id: project.id,
        resource_id: miv.id,
        resource_name: "test-image",
        billing_rate_id: BillingRate.from_resource_properties("MachineImageStorage", "standard", mi.location.name)["id"],
        amount: 10
      )
      expect(miv.active_billing_records).not_to be_empty
      miv.active_billing_records.each { expect(_1).to receive(:finalize).and_call_original }
      miv.destroy
    end

    it "destroys associated key_encryption_key" do
      kek = StorageKeyEncryptionKey.create(algorithm: "aes-256-gcm", key: "testkey", init_vector: "iv", auth_data: "auth")
      miv.update(key_encryption_key_1_id: kek.id)
      miv.destroy
      expect(StorageKeyEncryptionKey[kek.id]).to be_nil
    end

    it "destroys cleanly without KEK" do
      miv.destroy
      expect(described_class[miv.id]).to be_nil
    end
  end
end
