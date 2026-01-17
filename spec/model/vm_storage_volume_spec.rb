# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe VmStorageVolume do
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

  describe "#init_health_monitor_session" do
    let(:vm) { create_vm }
    let(:v) { described_class.create(disk_index: 0, vm_id: vm.id, size_gib: 40, boot: true) }

    it "returns empty hash if no vm host associated" do
      expect(v.init_health_monitor_session).to eq({})
    end

    it "returns empty hash if vm is nil" do
      orphan = described_class.new
      expect(orphan.init_health_monitor_session).to eq({})
    end

    it "starts a fresh ssh session from the host" do
      vm_host = create_vm_host
      vm.update(vm_host_id: vm_host.id)

      expect(v.vm.vm_host.sshable).to receive(:start_fresh_session).and_return("ssh_session")
      expect(v.init_health_monitor_session).to eq({ssh_session: "ssh_session"})
    end
  end

  describe "#check_pulse" do
    let(:vm_host) { create_vm_host }
    let(:vm) { create_vm(vm_host_id: vm_host.id, display_state: "running") }
    let(:volume) { described_class.create(disk_index: 0, vm_id: vm.id, size_gib: 40, boot: true) }
    let(:session) { {ssh_session: instance_double(Net::SSH::Connection::Session)} }
    let(:previous_pulse) { {reading: "up", reading_rpt: 1, reading_chg: Time.now} }

    context "when not vhost_block_backend" do
      it "returns up" do
        result = volume.check_pulse(session:, previous_pulse:)
        expect(result[:reading]).to eq("up")
        expect(volume).not_to receive(:aggregate_readings)
      end
    end

    context "when vm host is missing" do
      it "returns up" do
        backend = VhostBlockBackend.create(vm_host_id: vm_host.id, version: "test", allocation_weight: 100)
        volume.update(vhost_block_backend_id: backend.id, vring_workers: 2)

        vm.update(vm_host_id: nil)

        result = volume.check_pulse(session:, previous_pulse:)
        expect(result[:reading]).to eq("up")
      end
    end

    context "when vm is missing (orphan)" do
      it "returns up" do
        backend = VhostBlockBackend.create(vm_host_id: vm_host.id, version: "test", allocation_weight: 100)

        orphan = described_class.new(vhost_block_backend_id: backend.id, disk_index: 0)

        result = orphan.check_pulse(session:, previous_pulse:)
        expect(result[:reading]).to eq("up")
      end
    end

    context "when vm is not running" do
      it "returns up" do
        backend = VhostBlockBackend.create(vm_host_id: vm_host.id, version: "test", allocation_weight: 100)
        volume.update(vhost_block_backend_id: backend.id, vring_workers: 2)

        vm.update(display_state: "creating")

        result = volume.check_pulse(session:, previous_pulse:)
        expect(result[:reading]).to eq("up")
      end
    end

    context "when session is missing" do
      it "returns up" do
        backend = VhostBlockBackend.create(vm_host_id: vm_host.id, version: "test", allocation_weight: 100)
        volume.update(vhost_block_backend_id: backend.id, vring_workers: 2)

        result = volume.check_pulse(session: {}, previous_pulse:)
        expect(result[:reading]).to eq("up")
      end
    end

    context "when all conditions met" do
      before do
        backend = VhostBlockBackend.create(vm_host_id: vm_host.id, version: "test", allocation_weight: 100)
        volume.update(vhost_block_backend_id: backend.id, vring_workers: 2)
      end

      it "returns up when service is active" do
        expect(session[:ssh_session]).to receive(:exec!).with("systemctl is-active :service_name", service_name: "#{vm.inhost_name}-0-storage.service").and_return("active\n")
        result = volume.check_pulse(session:, previous_pulse:)
        expect(result[:reading]).to eq("up")
      end

      it "returns down when service is inactive" do
        expect(session[:ssh_session]).to receive(:exec!).with("systemctl is-active :service_name", service_name: "#{vm.inhost_name}-0-storage.service").and_return("inactive\n")
        expect(Clog).to receive(:emit).with(/systemd unit .* is not active/, anything)

        result = volume.check_pulse(session:, previous_pulse:)
        expect(result[:reading]).to eq("down")
      end

      it "returns down on ssh error" do
        expect(session[:ssh_session]).to receive(:exec!).and_raise(RuntimeError)
        expect(Clog).to receive(:emit).with(/check_pulse ssh error/, anything)
        expect(Clog).to receive(:emit).with(/systemd unit .* is not active/, anything)

        result = volume.check_pulse(session:, previous_pulse:)
        expect(result[:reading]).to eq("down")
      end

      it "raises IOError" do
        expect(session[:ssh_session]).to receive(:exec!).and_raise(IOError)
        expect { volume.check_pulse(session:, previous_pulse:) }.to raise_error(IOError)
      end

      it "raises Errno::ECONNRESET" do
        expect(session[:ssh_session]).to receive(:exec!).and_raise(Errno::ECONNRESET)
        expect { volume.check_pulse(session:, previous_pulse:) }.to raise_error(Errno::ECONNRESET)
      end
    end
  end
end
