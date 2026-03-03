# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe MachineImageVersion do
  let(:project) { Project.create(name: "test") }
  let(:location) { Location[Location::HETZNER_FSN1_ID] }

  let(:mi) {
    MachineImage.create(
      name: "test-image",
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
      s3_prefix: "test/prefix",
      s3_endpoint: "https://s3.example.com"
    )
  }

  describe "#activate!" do
    it "sets activated_at to current time" do
      expect(miv.activated_at).to be_nil
      miv.activate!
      expect(miv.reload.activated_at).to be_within(5).of(Time.now)
    end

    it "can be called on an already-activated version" do
      miv.activate!
      first_activation = miv.reload.activated_at
      sleep 0.01
      miv.activate!
      expect(miv.reload.activated_at).to be >= first_activation
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
      v2 = described_class.create(
        machine_image_id: mi.id,
        version: "v2",
        state: "available",
        size_gib: 10,
        s3_bucket: "test-bucket",
        s3_prefix: "test/prefix2",
        s3_endpoint: "https://s3.example.com"
      )
      v2.update(activated_at: Time.now + 100)

      expect(miv.reload.active?).to be false
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
    it "returns the correct archive parameters" do
      params = miv.archive_params
      expect(params["type"]).to eq("archive")
      expect(params["archive_bucket"]).to eq("test-bucket")
      expect(params["archive_prefix"]).to eq("test/prefix")
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

    it "has active_billing_records" do
      expect(miv.active_billing_records).to eq([])
    end
  end

  describe "ResourceMethods" do
    it "generates a ubid" do
      expect(miv.ubid).to match(/\A[a-z0-9]{26}\z/)
    end
  end

  describe "state values" do
    it "supports all valid states" do
      %w[creating available failed destroying].each do |state|
        miv.update(state: state)
        expect(miv.reload.state).to eq(state)
      end
    end
  end

  describe "#before_destroy" do
    it "nullifies referencing vm_storage_volumes" do
      vm = create_vm
      vol = VmStorageVolume.create(vm_id: vm.id, boot: false, size_gib: 10, disk_index: 1, machine_image_version_id: miv.id)

      miv.destroy
      expect(vol.reload.machine_image_version_id).to be_nil
    end

    it "finalizes active billing records" do
      billing_rate = BillingRate.from_resource_properties("VmVCpu", "standard", "hetzner-fsn1")
      br = BillingRecord.create(
        project_id: project.id,
        resource_id: miv.id,
        resource_name: "test",
        billing_rate_id: billing_rate["id"],
        amount: 10
      )
      # Set span to start in the past so finalize produces a non-empty range
      br.update(span: Sequel.pg_range(Time.now - 3600..nil))

      expect(BillingRecord.where(resource_id: miv.id).active.count).to eq(1)
      miv.destroy
      expect(BillingRecord.where(resource_id: miv.id).active.count).to eq(0)
    end

    it "destroys key_encryption_key_1 if present" do
      kek = StorageKeyEncryptionKey.create(
        algorithm: "aes-256-gcm",
        key: "test_key_data_for_kek_testing_00",
        init_vector: "test_iv_data",
        auth_data: "test_auth"
      )
      miv.update(key_encryption_key_1_id: kek.id)

      miv.destroy
      expect(StorageKeyEncryptionKey[kek.id]).to be_nil
    end
  end
end
