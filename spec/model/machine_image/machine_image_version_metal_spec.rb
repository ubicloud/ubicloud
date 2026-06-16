# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe MachineImageVersionMetal do
  describe "#display_state" do
    let(:metal) { create_machine_image_version_metal }

    it "returns the underlying status when no destroy semaphore is set" do
      metal.update(status: "creating")
      expect(metal.display_state).to eq("creating")
      metal.update(status: "ready", archive_size_mib: 1)
      expect(metal.reload.display_state).to eq("ready")
      metal.update(status: "failed", archive_size_mib: nil)
      expect(metal.reload.display_state).to eq("failed")
    end

    it "returns 'destroying' as soon as the destroy semaphore is set" do
      metal.update(status: "ready", archive_size_mib: 1)
      metal.incr_destroy
      expect(metal.reload.display_state).to eq("destroying")
    end

    it "returns 'destroying' once destroying semaphore is set" do
      metal.update(status: "ready", archive_size_mib: 1)
      metal.incr_destroying
      expect(metal.reload.display_state).to eq("destroying")
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
