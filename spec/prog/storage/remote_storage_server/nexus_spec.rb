# frozen_string_literal: true

require_relative "../../../model/spec_helper"

RSpec.describe Prog::Storage::RemoteStorageServer::Nexus do
  subject(:nx) { described_class.new(described_class.assemble(source_volume.id)) }

  let(:source_vm) { create_archive_ready_vm }
  let(:source_volume) { VmStorageVolume.first(vm_id: source_vm.id) }
  let(:rss) { nx.remote_storage_server }
  let(:sshable) { nx.sshable }

  describe ".assemble" do
    it "creates a server with a psk, identity, and free port" do
      expect(rss.source_vm_storage_volume).to eq(source_volume)
      expect(rss.port).to be_between(5500, 5999)
      expect(rss.psk).not_to be_nil
      expect(rss.psk_identity).to eq(rss.ubid)
      expect(rss.strand.label).to eq("start")
    end

    it "fails if the volume does not exist" do
      expect { described_class.assemble(SecureRandom.uuid) }.to raise_error("No existing VmStorageVolume")
    end

    it "fails if the source volume is unencrypted" do
      source_volume.update(key_encryption_key_1_id: nil)
      expect { described_class.assemble(source_volume.id) }.to raise_error("Source volume must be encrypted")
    end

    it "picks the next free port on the same host" do
      first = described_class.assemble(source_volume.id)
      second_volume = VmStorageVolume.create(
        vm_id: source_vm.id, boot: false, size_gib: 5, disk_index: 1,
        storage_device_id: source_volume.storage_device_id,
        vhost_block_backend_id: source_volume.vhost_block_backend_id,
        key_encryption_key_1_id: StorageKeyEncryptionKey.create_random(auth_data: "x").id,
        vring_workers: 1, track_written: true,
      )
      second = described_class.assemble(second_volume.id)
      ports = [RemoteStorageServer[first.id].port, RemoteStorageServer[second.id].port]
      expect(ports).to contain_exactly(5500, 5501)
    end
  end

  describe "#before_run" do
    it "hops to destroy when the destroy semaphore is set" do
      expect(nx).to receive(:when_destroy_set?).and_yield
      expect { nx.before_run }.to hop("destroy")
    end
  end

  describe "#start" do
    it "stops the source volume's vhost backend and hops to run_server" do
      expect(sshable).to receive(:cmd).with("sudo systemctl stop :unit", unit: source_volume.vhost_backend_systemd_unit_name)
      expect { nx.start }.to hop("run_server")
    end
  end

  describe "#run_server" do
    it "starts the daemon when it is not running" do
      expect(sshable).to receive(:d_check).with(nx.daemon_name).and_return("NotStarted")
      expect(sshable).to receive(:d_run) do |name, *args, **kwargs|
        expect(name).to eq(nx.daemon_name)
        expect(args).to include("host/bin/setup-remote-storage-server", rss.port.to_s, rss.psk_identity)
        expect(JSON.parse(kwargs[:stdin])).to include("kek", "psk")
      end
      expect { nx.run_server }.to nap(5)
    end

    it "hops to wait once the daemon is running" do
      expect(sshable).to receive(:d_check).with(nx.daemon_name).and_return("InProgress")
      expect { nx.run_server }.to hop("wait")
    end
  end

  describe "#wait" do
    it "naps while the daemon is running" do
      expect(sshable).to receive(:d_check).and_return("InProgress")
      expect { nx.wait }.to nap(30)
    end

    it "re-runs the server if the daemon died" do
      expect(sshable).to receive(:d_check).and_return("Failed")
      expect { nx.wait }.to hop("run_server")
    end
  end

  describe "#destroy" do
    it "stops the daemon and destroys the model" do
      expect(sshable).to receive(:d_stop).with(nx.daemon_name)
      expect(sshable).to receive(:d_clean).with(nx.daemon_name)
      id = rss.id
      expect { nx.destroy }.to exit({"msg" => "remote storage server destroyed"})
      expect(RemoteStorageServer[id]).to be_nil
    end
  end
end
