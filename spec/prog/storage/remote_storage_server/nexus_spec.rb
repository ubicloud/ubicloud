# frozen_string_literal: true

require_relative "../../../model/spec_helper"

RSpec.describe Prog::Storage::RemoteStorageServer::Nexus do
  subject(:nx) { described_class.new(described_class.assemble(source_volume.id)) }

  let(:source_vm) do
    vm = create_archive_ready_vm
    vm.strand.update(label: "stopped_by_admin")
    VhostBlockBackend.create(version: "0.5.1", allocation_weight: 100, vm_host_id: vm.vm_host_id)
    vm
  end
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
      expect { described_class.assemble(VmStorageVolume.generate_uuid) }.to raise_error("No existing VmStorageVolume")
    end

    it "fails if the source volume is unencrypted" do
      source_volume.update(key_encryption_key_1_id: nil)
      expect { described_class.assemble(source_volume.id) }.to raise_error("Source volume must be encrypted")
    end

    it "fails if the Vm is not in stopped_by_admin state" do
      source_vm.strand.update(label: "wait")
      expect { described_class.assemble(source_volume.id) }.to raise_error("VM isn't in stopped_by_admin state")
    end

    it "fails if the host doesn't have the necessary vhost_block_backend" do
      source_vm.vm_host.vhost_block_backends_dataset.where { version_code >= 500 }.destroy
      expect { described_class.assemble(source_volume.id) }.to raise_error(/\AHost doesn't have ubiblk /)
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

  describe "#start" do
    it "stops the source volume's vhost backend and hops to run_server" do
      expect(sshable).to receive(:_cmd).with("sudo systemctl stop #{source_volume.vhost_backend_systemd_unit_name}")
      expect { nx.start }.to hop("run_server")
      expect(nx.frame["deadline_target"]).to eq("wait")
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

    it "starts the daemona and emits when daemon is in Succeeded state" do
      expect(sshable).to receive(:d_check).with(nx.daemon_name).and_return("Succeeded")
      expect(sshable).to receive(:d_run) do |name, *args, **kwargs|
        expect(name).to eq(nx.daemon_name)
        expect(args).to include("host/bin/setup-remote-storage-server", rss.port.to_s, rss.psk_identity)
        expect(JSON.parse(kwargs[:stdin])).to include("kek", "psk")
      end
      expect(Clog).to receive(:emit).with("Remote storage server in unexpected state", {remote_storage_server_unexpected_state: {state: "Succeeded"}})
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
      expect(nx.frame["deadline_target"]).to be_nil
    end

    it "re-runs the server if the daemon died" do
      expect(sshable).to receive(:d_check).and_return("Failed")
      expect { nx.wait }.to hop("run_server")
      expect(nx.frame["deadline_target"]).to eq("wait")
    end
  end

  describe "#destroy" do
    it "stops the daemon and destroys the model" do
      expect(sshable).to receive(:d_check).with(nx.daemon_name).and_return("InProgress")
      expect(sshable).to receive(:d_stop).with(nx.daemon_name)
      expect(sshable).to receive(:d_clean).with(nx.daemon_name)
      expect { nx.destroy }.to exit({"msg" => "remote storage server destroyed"})
      expect(rss).not_to exist
    end

    it "handles case where daemon is not running" do
      expect(sshable).to receive(:d_check).with(nx.daemon_name).and_return("NotStarted")
      expect(sshable).to receive(:d_clean).with(nx.daemon_name)
      expect { nx.destroy }.to exit({"msg" => "remote storage server destroyed"})
      expect(rss).not_to exist
    end
  end

  describe "serving a detachable volume" do
    subject(:dnx) { described_class.new(described_class.assemble_for_detachable_volume(volume)) }

    let(:source_host) {
      host = create_vm_host
      VhostBlockBackend.create(version: "v0.5.1", allocation_weight: 0, vm_host_id: host.id)
      host
    }
    let(:volume) { create_detachable_volume(vm_host_id: source_host.id) }
    let(:server) { dnx.remote_storage_server }

    it "serves from the volume's host" do
      expect(server.source_detachable_volume_id).to eq(volume.id)
      expect(server.source_vm_storage_volume_id).to be_nil
      expect(server.vm_host.id).to eq(source_host.id)
      expect(server.strand.label).to eq("start")
    end

    it "fails for a volume that is on no host" do
      volume.update(vm_host_id: nil)
      expect { described_class.assemble_for_detachable_volume(volume) }.to raise_error("Detachable volume is not on a host")
    end

    it "fails if the host doesn't have the necessary vhost_block_backend" do
      volume.update(vm_host_id: create_vm_host.id)
      expect { described_class.assemble_for_detachable_volume(volume) }.to raise_error(/\AHost doesn't have ubiblk /)
    end

    it "stops the volume's backend so the server can open it" do
      expect(dnx.sshable).to receive(:_cmd).with("sudo host/bin/detachable-volume stop #{volume.ubid}").and_return(JSON.generate({"caught_up" => true}))
      expect { dnx.start }.to hop("run_server")
    end

    it "runs host/bin/detachable-volume serve with the keys on stdin" do
      expect(dnx.sshable).to receive(:d_check).with(dnx.daemon_name).and_return("NotStarted")
      expect(dnx.sshable).to receive(:d_run) do |name, *args, stdin:|
        expect(name).to eq(dnx.daemon_name)
        expect(args).to eq(["sudo", "host/bin/detachable-volume", "serve", volume.ubid])
        expect(JSON.parse(stdin)).to eq({
          "kek" => volume.key_encryption_key_1.key, "psk" => server.psk, "psk_identity" => server.psk_identity,
          "port" => server.port, "server_version" => "v0.5.1",
        })
      end
      expect { dnx.run_server }.to nap(5)
    end

    it "deletes the copy it served once the volume lives on another host" do
      server.source_detachable_volume.update(vm_host_id: create_vm_host.id)
      expect(dnx.sshable).to receive(:d_check).and_return("NotStarted")
      expect(dnx.sshable).to receive(:d_clean)
      expect(dnx.sshable).to receive(:_cmd).with("sudo host/bin/detachable-volume delete #{volume.ubid}").and_return(JSON.generate({"deleted" => true}))
      expect { dnx.destroy }.to exit({"msg" => "remote storage server destroyed"})
    end

    it "keeps the copy when the volume never left" do
      expect(dnx.sshable).to receive(:d_check).and_return("NotStarted")
      expect(dnx.sshable).to receive(:d_clean)
      expect(dnx.sshable).not_to receive(:_cmd)
      expect { dnx.destroy }.to exit({"msg" => "remote storage server destroyed"})
    end
  end
end
