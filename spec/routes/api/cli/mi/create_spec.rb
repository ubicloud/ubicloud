# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Clover, "cli mi create" do
  before do
    @project.set_ff_machine_image(true)
    vm_host = create_vm_host
    vbb = VhostBlockBackend.create(version: "v0.4.0", allocation_weight: 100, vm_host_id: vm_host.id)
    @vm = Prog::Vm::Nexus.assemble("dummy-public key", @project.id, name: "stopped-vm", location_id: Location::HETZNER_FSN1_ID).subject
    @vm.strand.update(label: "stopped")
    VmStorageVolume.create(vm_id: @vm.id, boot: true, size_gib: 20, disk_index: 0, vhost_block_backend_id: vbb.id, vring_workers: 1)
  end

  it "creates machine image" do
    body = cli(["mi", "eu-central-h1/my-image", "create", "-v", @vm.ubid])
    mi = MachineImage.first(name: "my-image")
    expect(mi).not_to be_nil
    ver = mi.versions.first
    expect(ver.state).to eq "creating"
    expect(body).to eq "Machine image created with id: #{mi.ubid}\n"
  end

  it "creates machine image with description" do
    body = cli(["mi", "eu-central-h1/my-image", "create", "-v", @vm.ubid, "-d", "test description"])
    mi = MachineImage.first(name: "my-image")
    expect(mi).not_to be_nil
    expect(mi.description).to eq "test description"
    expect(body).to eq "Machine image created with id: #{mi.ubid}\n"
  end
end
