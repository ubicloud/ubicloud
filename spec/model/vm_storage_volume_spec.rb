# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe VmStorageVolume do
  it "can render a device_path" do
    vm = Vm.new(location: Location[Location::HETZNER_FSN1_ID]).tap { it.id = "eb3dbcb3-2c90-8b74-8fb4-d62a244d7ae5" }
    expect(described_class.new(disk_index: 7, vm: vm).device_path).to eq("/dev/disk/by-id/virtio-vmxcyvsc_7")
  end

  it "can render a device_path for aws" do
    prj = Project.create(name: "test-project")
    vm = Vm.new(location: Location.create(name: "us-west-2", provider: "aws", project_id: prj.id, display_name: "aws-us-west-2", ui_name: "AWS US East 1", visible: true)).tap { it.id = "eb3dbcb3-2c90-8b74-8fb4-d62a244d7ae5" }
    expect(described_class.new(disk_index: 2, vm: vm).device_path).to eq("/dev/nvme2n1")
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

  describe "#num_queues" do
    it "returns 1 for SPDK volumes" do
      v = described_class.new(disk_index: 7, vring_workers: 5)
      allow(v).to receive(:vhost_block_backend).and_return(nil)
      expect(v.num_queues).to eq(1)
    end

    it "returns vring_workers for vhost_block_backend volumes" do
      vm = Vm.new(vcpus: 4).tap { it.id = "eb3dbcb3-2c90-8b74-8fb4-d62a244d7ae5" }
      v = described_class.new(disk_index: 7, vm: vm, vring_workers: 5)
      allow(v).to receive(:vhost_block_backend).and_return(VhostBlockBackend.new)
      expect(v.num_queues).to eq(5)
    end
  end

  describe "#queue_size" do
    it "returns 256 for SPDK volumes" do
      v = described_class.new(disk_index: 7)
      allow(v).to receive(:vhost_block_backend).and_return(nil)
      expect(v.queue_size).to eq(256)
    end

    it "returns 64 for vhost_block_backend volumes" do
      v = described_class.new(disk_index: 7)
      allow(v).to receive(:vhost_block_backend).and_return(VhostBlockBackend.new)
      expect(v.queue_size).to eq(64)
    end
  end
end
