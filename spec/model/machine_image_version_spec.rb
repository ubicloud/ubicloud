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

  let(:version_attrs) {
    {
      machine_image_id: mi.id,
      version: "v1",
      state: "available",
      size_gib: 10,
      s3_bucket: "test-bucket",
      s3_prefix: "test-prefix",
      s3_endpoint: "https://s3.example.com"
    }
  }

  let(:miv) { described_class.create(**version_attrs) }

  describe "#activate!" do
    it "sets activated_at to current time" do
      expect(miv.activated_at).to be_nil
      miv.activate!
      expect(miv.reload.activated_at).to be_within(5).of(Time.now)
    end

    it "can be called multiple times" do
      miv.activate!
      first_activated = miv.reload.activated_at
      sleep 0.01
      miv.activate!
      expect(miv.reload.activated_at).to be >= first_activated
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
      miv.update(activated_at: Time.now - 100)
      described_class.create(**version_attrs.merge(version: "v2", activated_at: Time.now))
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
    it "belongs to a machine_image" do
      expect(miv.machine_image.id).to eq(mi.id)
    end
  end

  describe "ResourceMethods" do
    it "generates a UBID" do
      expect(miv.ubid).to start_with("mv")
    end
  end

  describe "state values" do
    it "supports creating state" do
      v = described_class.create(**version_attrs.merge(version: "v-creating", state: "creating"))
      expect(v.state).to eq("creating")
    end

    it "supports failed state" do
      v = described_class.create(**version_attrs.merge(version: "v-failed", state: "failed"))
      expect(v.state).to eq("failed")
    end

    it "supports destroying state" do
      v = described_class.create(**version_attrs.merge(version: "v-destroying", state: "destroying"))
      expect(v.state).to eq("destroying")
    end
  end

  describe "#before_destroy" do
    it "finalizes active billing records" do
      original_end = Time.now + 3600
      br = BillingRecord.create(
        project_id: project.id,
        resource_id: miv.id,
        resource_name: "test",
        billing_rate_id: BillingRate.from_resource_properties("MachineImageStorage", "standard", "hetzner-fsn1")["id"],
        amount: 10,
        span: Sequel.pg_range(Time.now..original_end)
      )
      miv.destroy
      expect(br.reload.span.end).to be < original_end
    end

    it "nullifies vm_storage_volume references" do
      vm = create_vm

      vsv = VmStorageVolume.create(
        vm_id: vm.id, boot: true, size_gib: 10,
        disk_index: 0,
        machine_image_version_id: miv.id
      )

      miv.destroy
      expect(vsv.reload.machine_image_version_id).to be_nil
    end

    it "destroys associated key_encryption_key" do
      kek = StorageKeyEncryptionKey.create(
        algorithm: "aes-256-gcm",
        key: "k" * 64,
        init_vector: "iv" * 12,
        auth_data: "ad"
      )
      miv.update(key_encryption_key_1_id: kek.id)
      miv.destroy
      expect(StorageKeyEncryptionKey[kek.id]).to be_nil
    end
  end
end
