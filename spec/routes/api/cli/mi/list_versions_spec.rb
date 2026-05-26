# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Clover, "cli mi list-versions" do
  let(:location_id) { Location[display_name: TEST_LOCATION].id }

  before do
    @project.set_ff_machine_image(true)
    @mi_metal = create_machine_image_version_metal(project_id: @project.id, location_id:)
    @mi = @mi_metal.machine_image_version.machine_image
    @miv = @mi_metal.machine_image_version
  end

  it "lists versions without headers when -N is given" do
    body = cli(%W[mi eu-central-h1/#{@mi.name} list-versions -N])
    expect(body).to eq("v1  #{@miv.ubid}  ready  5120  1024  #{@miv.created_at.iso8601}  0\n")
  end

  it "shows headers by default" do
    body = cli(%W[mi eu-central-h1/#{@mi.name} list-versions])
    expect(body).to eq("version  id                          state  actual-size-mib  archive-size-mib  created-at                 vms-count\nv1       #{@miv.ubid}  ready  5120             1024              #{@miv.created_at.iso8601}  0        \n")
  end

  it "restricts fields with -f" do
    body = cli(%W[mi eu-central-h1/#{@mi.name} list-versions -N -f version])
    expect(body).to eq("v1\n")
  end

  it "reports the count of VMs using each version" do
    vbb = create_vhost_block_backend(allocation_weight: 100, vm_host_id: create_vm_host(location_id:).id)
    sd = StorageDevice.create(name: "vda", total_storage_gib: 100, available_storage_gib: 50, vm_host_id: vbb.vm_host_id)
    vm = create_vm(project_id: @project.id, location_id:, vm_host_id: vbb.vm_host_id)
    VmStorageVolume.create(
      vm_id: vm.id, boot: true, size_gib: 5, disk_index: 0,
      storage_device_id: sd.id,
      vhost_block_backend_id: vbb.id,
      machine_image_version_id: @miv.id,
      key_encryption_key_1_id: StorageKeyEncryptionKey.create_random(auth_data: "k").id,
      vring_workers: 1,
    )

    body = cli(%W[mi eu-central-h1/#{@mi.name} list-versions -N -f version,vms-count])
    expect(body).to eq("v1  1\n")
  end
end
