# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe VmStorageVolume do
  it "can render a device_path" do
    vm = Vm.new(location: Location[Location::HETZNER_FSN1_ID]).tap { it.id = "eb3dbcb3-2c90-8b74-8fb4-d62a244d7ae5" }
    expect(described_class.new(disk_index: 7, vm: vm).device_path).to eq("/dev/disk/by-id/virtio-vmxcyvsc_7")
  end

  it "can render a device_path for aws" do
    prj = Project.create_with_id(name: "test-project")
    vm = Vm.new(location: Location.create_with_id(name: "us-east-1", provider: "aws", project_id: prj.id, display_name: "aws-us-east-1", ui_name: "AWS US East 1", visible: true)).tap { it.id = "eb3dbcb3-2c90-8b74-8fb4-d62a244d7ae5" }
    expect(described_class.new(disk_index: 7, vm: vm).device_path).to eq("/dev/nvme1n1")
  end

  it "returns correct spdk version if exists associated installation" do
    si = SpdkInstallation.new(version: "some-version")
    v = described_class.new(disk_index: 7)
    allow(v).to receive(:spdk_installation).and_return(si)
    expect(v.spdk_version).to eq("some-version")
  end

  it "returns nil spdk version if no associated installation" do
    v = described_class.new(disk_index: 7)
    allow(v).to receive(:spdk_installation).and_return(nil)
    expect(v.spdk_version).to be_nil
  end

  it "returns correct vhost_block_backend version if exists associated installation" do
    vbb = VhostBlockBackend.new(version: "some-vhost-version")
    v = described_class.new(disk_index: 7)
    allow(v).to receive(:vhost_block_backend).and_return(vbb)
    expect(v.vhost_block_backend_version).to eq("some-vhost-version")
  end

  it "returns nil vhost_block_backend version if no associated installation" do
    v = described_class.new(disk_index: 7)
    allow(v).to receive(:vhost_block_backend).and_return(nil)
    expect(v.vhost_block_backend_version).to be_nil
  end
end
