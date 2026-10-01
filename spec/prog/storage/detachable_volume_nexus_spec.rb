# frozen_string_literal: true

require_relative "../../model/spec_helper"

RSpec.describe Prog::Storage::DetachableVolumeNexus do
  subject(:nx) { described_class.new(volume.strand) }

  let(:host) { create_vm_host }
  let(:volume) { create_detachable_volume(vm_host_id: host.id).reload }

  def expect_host_command(command, result = {})
    expect(nx.detachable_volume.vm_host.sshable).to receive(:_cmd)
      .with("sudo host/bin/detachable-volume #{command} #{volume.ubid}").and_return(JSON.generate(result))
  end

  def host_failure
    Sshable::SshError.new("sudo host/bin/detachable-volume", "", "down", 1, nil)
  end

  describe ".assemble" do
    it "creates a new volume with keys of its own and a strand" do
      project = Project.create(name: "volume-owner")
      v = described_class.assemble(project_id: project.id, location_id: Location::HETZNER_FSN1_ID,
        size_gib: 4, source_image: "seed-image")
      expect(v.size_gib).to eq(4)
      expect(v.vm_host_id).to be_nil
      expect(v.key_encryption_key_1.auth_data).to eq(v.ubid)
      expect(v.wrapped_xts).not_to be_nil
      expect(v.strand.label).to eq("wait")
    end
  end

  describe "#wait" do
    it "naps when there is nothing to do" do
      expect { nx.wait }.to nap(30 * 24 * 60 * 60)
    end

    it "hops to destroy when asked" do
      volume.incr_destroy
      expect { nx.wait }.to hop("destroy")
    end

    it "waits for a volume that is still fetching" do
      volume.incr_catch_up
      expect { nx.wait }.to hop("wait_catch_up")
      expect(Semaphore.where(strand_id: volume.id).select_map(:name)).to eq([])
    end
  end

  describe "#wait_catch_up" do
    it "keeps waiting while stripes are outstanding" do
      expect_host_command("status", {"stripes" => {"fetched" => 10, "source" => 1536}, "caught_up" => false})
      expect { nx.wait_catch_up }.to nap(5)
    end

    it "goes back to waiting once the volume has caught up" do
      expect_host_command("status", {"stripes" => {"fetched" => 1536, "source" => 1536}, "caught_up" => true})
      expect { nx.wait_catch_up }.to hop("wait")
    end

    it "forgets the source and releases the server once everything is local" do
      server = RemoteStorageServer.create(source_detachable_volume_id: volume.id, vm_host_id: create_vm_host.id,
        psk: "psk", psk_identity: "id", port: 5500)
      Strand.create_with_id(server, prog: "Storage::RemoteStorageServer::Nexus", label: "wait")

      expect_host_command("status", {"stripes" => {"fetched" => 5, "source" => 5}, "caught_up" => true}).ordered
      expect_host_command("drop-source", {"dropped" => true}).ordered
      expect { nx.wait_catch_up }.to hop("wait")
      expect(server.reload.destroy_set?(cached: false)).to be true
    end

    it "keeps waiting when the host does not say it is caught up" do
      expect_host_command("status")
      expect { nx.wait_catch_up }.to nap(5)
    end

    it "leaves a host that cannot be reached to the strand's retries" do
      expect(nx.detachable_volume.vm_host.sshable).to receive(:_cmd).and_raise(host_failure)
      expect { nx.wait_catch_up }.to raise_error(Sshable::SshError)
    end
  end

  describe "#destroy" do
    it "stops serving a move first" do
      server = RemoteStorageServer.create(source_detachable_volume_id: volume.id, vm_host_id: create_vm_host.id,
        psk: "psk", psk_identity: "id", port: 5500)
      Strand.create_with_id(server, prog: "Storage::RemoteStorageServer::Nexus", label: "wait")
      expect { nx.destroy }.to hop("wait_remote_storage_server_destroyed")
      expect(server.reload.destroy_set?(cached: false)).to be true
    end

    it "waits for a key rotation to finish" do
      volume.update(key_encryption_key_2_id: StorageKeyEncryptionKey.create_random(auth_data: "k2").id)
      expect { nx.destroy }.to nap(5)
    end

    it "moves on straight away when nothing serves it" do
      volume.incr_destroy
      expect { nx.destroy }.to hop("wait_remote_storage_server_destroyed")
      expect(Semaphore.where(strand_id: volume.id).select_map(:name)).to eq([])
    end
  end

  describe "#wait_remote_storage_server_destroyed" do
    it "waits while a server still reads from the volume" do
      server = RemoteStorageServer.create(source_detachable_volume_id: volume.id, vm_host_id: create_vm_host.id,
        psk: "psk", psk_identity: "id", port: 5500)
      Strand.create_with_id(server, prog: "Storage::RemoteStorageServer::Nexus", label: "destroy")
      expect { nx.wait_remote_storage_server_destroyed }.to nap(5)
    end

    it "deletes the volume once no server reads from it" do
      expect { nx.wait_remote_storage_server_destroyed }.to hop("delete_from_host")
    end
  end

  describe "#delete_from_host" do
    it "removes the local copy, the row and the keys" do
      kek = volume.key_encryption_key_1
      expect_host_command("delete", {"deleted" => true})
      expect { nx.delete_from_host }.to exit({"msg" => "detachable volume destroyed"})
      expect(volume).not_to exist
      expect(kek).not_to exist
    end

    it "leaves a host that cannot be reached to the strand's retries, keeping the row" do
      expect(nx.detachable_volume.vm_host.sshable).to receive(:_cmd).and_raise(host_failure)
      expect { nx.delete_from_host }.to raise_error(Sshable::SshError)
      expect(volume).to exist
    end

    it "does not call the host when there is nothing there" do
      volume.update(vm_host_id: nil)
      expect { nx.delete_from_host }.to exit({"msg" => "detachable volume destroyed"})
      expect(volume).not_to exist
    end
  end
end
