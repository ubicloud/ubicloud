# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe MachineImageVersionMetal do
  let(:project) { Project.create(name: "test-mi-project") }
  let(:vm_host) { create_vm_host }
  let(:vhost_block_backend) { create_vhost_block_backend(allocation_weight: 50, vm_host_id: vm_host.id) }
  let(:source_vm) {
    vm = create_vm(vm_host_id: vm_host.id, project_id: project.id)
    Strand.create_with_id(vm, prog: "Vm::Nexus", label: "stopped")
    sd = StorageDevice.create(name: "vda", total_storage_gib: 100, available_storage_gib: 50, vm_host_id: vm_host.id)
    VmStorageVolume.create(
      vm_id: vm.id, boot: true, size_gib: 5, disk_index: 0,
      storage_device_id: sd.id, vhost_block_backend_id: vhost_block_backend.id,
      key_encryption_key_1_id: StorageKeyEncryptionKey.create_random(auth_data: "src-kek").id,
      vring_workers: 1,
    )
    vm
  }
  let(:machine_image) { MachineImage.create(name: "test-image", arch: "x64", project_id: project.id, location_id: Location::HETZNER_FSN1_ID) }
  let(:store) {
    MachineImageStore.create(
      project_id: project.id,
      location_id: Location::HETZNER_FSN1_ID,
      provider: "minio",
      region: "eu",
      endpoint: "https://minio.example.com/",
      bucket: "test-bucket",
      access_key: "ak",
      secret_key: "sk",
    )
  }
  let(:strand) { Prog::MachineImage::VersionMetalNexus.assemble_from_vm(machine_image, "1.0", source_vm, store) }
  let(:miv) { strand.subject }
  let(:metal) { miv.metal }

  describe "#request_destroy" do
    it "disables metal and inserts a destroy semaphore" do
      strand
      metal.update(enabled: true, archive_size_mib: 100)
      expect {
        metal.request_destroy
      }.to change { metal.reload.enabled }.from(true).to(false)
        .and change { Semaphore.where(strand_id: metal.id, name: "destroy").count }.by(1)
    end

    it "fails when the version is the latest" do
      strand
      machine_image.update(latest_version_id: miv.id)
      expect {
        metal.request_destroy
      }.to raise_error("Cannot destroy the latest version of a machine image")
    end

    it "fails when VMs are still using the version" do
      strand
      vm_host_for_use = create_vm_host
      vhost = create_vhost_block_backend(allocation_weight: 50, vm_host_id: vm_host_for_use.id)
      vm = create_vm(vm_host_id: vm_host_for_use.id, project_id: project.id, name: "consumer-vm")
      sd = StorageDevice.create(name: "vda", total_storage_gib: 100, available_storage_gib: 50, vm_host_id: vm_host_for_use.id)
      VmStorageVolume.create(
        vm_id: vm.id, boot: true, size_gib: 5, disk_index: 0,
        storage_device_id: sd.id, vhost_block_backend_id: vhost.id,
        key_encryption_key_1_id: StorageKeyEncryptionKey.create_random(auth_data: "k").id,
        machine_image_version_id: miv.id, vring_workers: 1,
      )
      expect {
        metal.request_destroy
      }.to raise_error("VMs are still using this machine image version")
    end
  end
end
