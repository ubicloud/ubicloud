# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe VmStorageVolume do
  let(:vm_host) { create_vm_host }
  let(:vm) { create_vm(vm_host_id: vm_host.id) }
  let(:default_storage_device) { StorageDevice.create(vm_host_id: vm_host.id, name: "DEFAULT", total_storage_gib: 100, available_storage_gib: 100) }

  it "can render a device_path" do
    vm = Vm.new(location: Location[Location::HETZNER_FSN1_ID]).tap { it.id = "eb3dbcb3-2c90-8b74-8fb4-d62a244d7ae5" }
    expect(described_class.new(disk_index: 7, vm:).device_path).to eq("/dev/disk/by-id/virtio-vmxcyvsc_7")
  end

  it "can render a device_path for aws" do
    prj = Project.create(name: "test-project")
    vm = Vm.new(location: Location.create(name: "us-west-2", provider: "aws", project_id: prj.id, display_name: "aws-us-west-2", ui_name: "AWS US East 1", visible: true)).tap { it.id = "eb3dbcb3-2c90-8b74-8fb4-d62a244d7ae5" }
    expect(described_class.new(disk_index: 2, vm:).device_path).to eq("/dev/nvme2n1")
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
    vbb = VhostBlockBackend.new(version_code: 10402)
    v = described_class.new(disk_index: 7)
    allow(v).to receive(:vhost_block_backend).and_return(vbb)
    expect(v.vhost_block_backend_version).to eq("v1.4.2")
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
      v = described_class.new(disk_index: 7, vm:, vring_workers: 5)
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

  describe "#path" do
    it "returns the correct path for the volume in the default storage device" do
      vol = described_class.create(vm_id: vm.id, disk_index: 3, storage_device_id: default_storage_device.id, boot: false, size_gib: 10)
      expect(vol.path).to eq("/var/storage/#{vm.inhost_name}/3")
    end

    it "returns the correct path for the volume in a non-default storage device" do
      storage_device = StorageDevice.create(vm_host_id: vm.vm_host_id, name: "disk1", total_storage_gib: 100, available_storage_gib: 100)
      vol = described_class.create(vm_id: vm.id, disk_index: 2, storage_device_id: storage_device.id, boot: false, size_gib: 10)
      expect(vol.path).to eq("/var/storage/devices/disk1/#{vm.inhost_name}/2")
    end
  end

  describe "#rpc" do
    it "sends a json payload to the rpc socket and parses the response" do
      vol = described_class.create(vm_id: vm.id, disk_index: 1, storage_device_id: default_storage_device.id, boot: false, size_gib: 10)
      payload = {"command" => "version"}
      allow(vol.vm.vm_host.sshable).to receive(:_cmd).with("sudo nc -U /var/storage/#{vm.inhost_name}/1/rpc.sock -q 2 -w 2 | head -n 1", stdin: payload.to_json).and_return('{"version":"v0.4.1"}')
      expect(vol.rpc(**payload)).to eq({"version" => "v0.4.1"})
    end
  end

  describe "#caught_up?" do
    let(:vol) { described_class.create(vm_id: vm.id, disk_index: 1, storage_device_id: default_storage_device.id, boot: false, size_gib: 10) }

    it "is true when stripes fetched equals source" do
      payload = {"command" => "status"}
      allow(vol.vm.vm_host.sshable).to receive(:_cmd).with("sudo nc -U /var/storage/#{vm.inhost_name}/1/rpc.sock -q 2 -w 2 | head -n 1", stdin: payload.to_json).and_return('{"status": {"stripes": {"fetched": 100, "source": 100}}}')
      expect(vol.caught_up?).to be true
    end

    it "is false when stripes fetched differs from source" do
      payload = {"command" => "status"}
      allow(vol.vm.vm_host.sshable).to receive(:_cmd).with("sudo nc -U /var/storage/#{vm.inhost_name}/1/rpc.sock -q 2 -w 2 | head -n 1", stdin: payload.to_json).and_return('{"status": {"stripes": {"fetched": 50, "source": 100}}}')
      expect(vol.caught_up?).to be false
    end
  end
end
