# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Clover, "cli vm start" do
  before do
    cli(%w[vm eu-central-h1/test-vm create] << "a a")
    @vm = Vm.first
  end

  it "restarts vm" do
    @vm.strand.update(label: "stopped")
    expect do
      expect(cli(%w[vm eu-central-h1/test-vm start])).to eq("Scheduled start of VM with id #{@vm.ubid}\n")
    end.to change { Semaphore.where(strand_id: @vm.id, name: "start").count }.from(0).to(1)
  end

  it "raises error if VM is not in the correct state" do
    expect do
      expect(cli(%w[vm eu-central-h1/test-vm start], status: 400)).to eq "! Unexpected response status: 400\nDetails: The start action is not supported in the VM's current state\n"
    end.to not_change { Semaphore.where(strand_id: @vm.id, name: "start").count }
  end

  it "raises error if running on AWS" do
    @vm.update(location: Location[name: "us-east-1"])
    expect do
      expect(cli(%w[vm us-east-1/test-vm start], status: 400)).to eq "! Unexpected response status: 400\nDetails: The start action is not supported for VMs running on us-east-1\n"
    end.to not_change { Semaphore.where(strand_id: @vm.id, name: "start").count }
  end

  it "raises error if a machine image is being archived from this VM" do
    @vm.strand.update(label: "stopped")
    store = MachineImageStore.create(project_id: @project.id, location_id: @vm.location_id,
      provider: "minio", region: "eu", endpoint: "https://example.com/", bucket: "b",
      access_key: "ak", secret_key: "sk")
    mi = MachineImage.create(project_id: @project.id, location_id: @vm.location_id, name: "captured-start", arch: @vm.arch)
    miv = MachineImageVersion.create(machine_image_id: mi.id, version: "1.0", actual_size_mib: 1024)
    MachineImageVersionMetal.create_with_id(miv,
      status: "creating", pinned_source_vm_id: @vm.id,
      archive_kek_id: StorageKeyEncryptionKey.create_random(auth_data: "k").id,
      store_id: store.id, store_prefix: "p")

    expect do
      expect(cli(%w[vm eu-central-h1/test-vm start], status: 400)).to eq "! Unexpected response status: 400\nDetails: Cannot start a VM while a machine image is being archived from it\n"
    end.to not_change { Semaphore.where(strand_id: @vm.id, name: "start").count }
  end
end
