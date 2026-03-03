# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe MachineImageVersion do
  let(:project) { Project.create(name: "test-miv-project") }
  let(:location) { Location[Location::HETZNER_FSN1_ID] }
  let(:mi) { MachineImage.create(name: "test-image", project_id: project.id, location_id: location.id) }

  let(:miv) {
    described_class.create(
      machine_image_id: mi.id, version: "v1", state: "available",
      size_gib: 10, s3_bucket: "bucket", s3_prefix: "prefix", s3_endpoint: "endpoint"
    )
  }

  describe "#activate!" do
    it "sets activated_at to the current time" do
      expect(miv.activated_at).to be_nil
      miv.activate!
      expect(miv.reload.activated_at).to be_within(5).of(Time.now)
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

    it "returns false when a newer version is active" do
      miv.activate!
      described_class.create(
        machine_image_id: mi.id, version: "v2", state: "available",
        size_gib: 10, s3_bucket: "b", s3_prefix: "p", s3_endpoint: "e",
        activated_at: Time.now + 100
      )
      expect(miv.active?).to be false
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
    it "returns the expected hash" do
      params = miv.archive_params
      expect(params).to eq({
        "type" => "archive",
        "archive_bucket" => "bucket",
        "archive_prefix" => "prefix",
        "archive_endpoint" => "endpoint",
        "compression" => "zstd",
        "encrypted" => true,
        "has_session_token" => true
      })
    end
  end

  describe "associations" do
    it "belongs to a machine_image" do
      expect(miv.machine_image.id).to eq(mi.id)
    end

    it "can have a vm association" do
      vm = create_vm(project_id: project.id)
      miv.update(vm_id: vm.id)
      expect(miv.reload.vm.id).to eq(vm.id)
    end
  end

  describe "#before_destroy" do
    it "nullifies referencing vm_storage_volumes" do
      miv.destroy
      expect(described_class[miv.id]).to be_nil
    end

    it "finalizes active billing records" do
      br = BillingRecord.create(
        project_id: project.id,
        resource_id: miv.id,
        resource_name: "test",
        billing_rate_id: BillingRate.from_resource_properties("VmCores", "standard", "hetzner-fsn1")["id"],
        amount: 1
      )
      expect(miv.active_billing_records.count).to eq(1)
      miv.destroy
      expect(br.reload.span.empty?).to be true
    end

    it "destroys key encryption key" do
      kek = StorageKeyEncryptionKey.create(
        algorithm: "aes-256-gcm",
        key: "k" * 32,
        init_vector: "iv12bytes123",
        auth_data: "auth"
      )
      miv.update(key_encryption_key_1_id: kek.id)
      miv.destroy
      expect(StorageKeyEncryptionKey[kek.id]).to be_nil
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
end
