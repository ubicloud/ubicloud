# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe VmStorageVolume do
  let(:project) { Project.create(name: "gcp-vsv-test") }
  let(:location) {
    Location.create(name: "gcp-us-central1", provider: "gcp",
      display_name: "GCP US Central 1", ui_name: "GCP US Central 1", visible: true)
  }

  let(:vm) {
    create_vm(
      project_id: project.id,
      location_id: location.id,
      name: "gcp-storage-test",
      memory_gib: 8,
      family: "c3d-standard",
      vcpus: 8
    )
  }

  context "with GCP provider" do
    describe "#device_path" do
      it "returns LSSD device path for non-boot, non-burstable VMs with 4+ vCPUs" do
        vol = described_class.create(vm_id: vm.id, boot: false, size_gib: 375, disk_index: 1)
        expect(vol.device_path).to eq("/dev/disk/by-id/google-local-nvme-ssd-0")
      end

      it "returns persistent disk path for boot volumes" do
        vol = described_class.create(vm_id: vm.id, boot: true, size_gib: 20, disk_index: 0)
        expect(vol.device_path).to eq("/dev/disk/by-id/google-persistent-disk-0")
      end

      it "returns persistent disk path for burstable VMs" do
        vm.update(family: "burstable", vcpus: 2)
        vol = described_class.create(vm_id: vm.id, boot: false, size_gib: 30, disk_index: 1)
        expect(vol.device_path).to eq("/dev/disk/by-id/google-persistent-disk-1")
      end

      it "returns persistent disk path for VMs with fewer than 4 vCPUs" do
        vm.update(vcpus: 2)
        vol = described_class.create(vm_id: vm.id, boot: false, size_gib: 30, disk_index: 1)
        expect(vol.device_path).to eq("/dev/disk/by-id/google-persistent-disk-1")
      end

      it "handles higher disk indexes for LSSD volumes" do
        vol = described_class.create(vm_id: vm.id, boot: false, size_gib: 375, disk_index: 3)
        expect(vol.device_path).to eq("/dev/disk/by-id/google-local-nvme-ssd-2")
      end
    end
  end
end
