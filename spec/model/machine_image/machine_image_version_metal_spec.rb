# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe MachineImageVersionMetal do
  let(:metal) {
    described_class.new(
      archive_kek_id: StorageKeyEncryptionKey.create_random(auth_data: "k").id,
      store_id: nil, store_prefix: "p", enabled: false, archive_size_mib: nil,
    )
  }

  describe "#display_state" do
    it "is creating while archive hasn't populated archive_size_mib yet" do
      expect(metal.display_state).to eq("creating")
    end

    it "is ready once enabled" do
      metal.set(enabled: true, archive_size_mib: 100)
      expect(metal.display_state).to eq("ready")
    end

    it "is destroying after enabled is flipped back to false" do
      metal.set(enabled: false, archive_size_mib: 100)
      expect(metal.display_state).to eq("destroying")
    end
  end

  describe "#create_billing_record" do
    let(:persisted_metal) { create_machine_image_version_metal(name: "ubuntu", version: "1.0") }

    it "creates a billing record sized in GiB for the image archive" do
      expect { persisted_metal.create_billing_record }.to change(BillingRecord, :count).by(1)
      br = BillingRecord.where(resource_id: persisted_metal.id).first
      expect(br.resource_name).to eq("ubuntu:1.0")
      expect(br.amount).to eq(1)
      expect(BillingRate.from_id(br.billing_rate_id)).to include("resource_type" => "MachineImageStorage", "location" => "hetzner-fsn1")
    end

    it "skips when project is not billable" do
      persisted_metal.machine_image_version.machine_image.project.update(billable: false)
      expect { persisted_metal.create_billing_record }.not_to change(BillingRecord, :count)
    end
  end
end
