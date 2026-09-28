# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe DetachableVolume do
  let(:volume) { create_detachable_volume }

  it "generates dv-prefixed ubids" do
    expect(described_class.generate_ubid.to_s).to start_with("dv")
  end

  it "starts out with no data anywhere" do
    expect(volume.vm_host_id).to be_nil
  end

  describe "#record_host" do
    let(:host) { create_vm_host }

    it "records the host that holds its data" do
      volume.record_host(host:, caught_up: true)
      expect(volume.reload.vm_host_id).to eq(host.id)
    end

    it "has its strand watch a catch-up that is still going" do
      volume.record_host(host:, caught_up: false)
      expect(volume.reload.catch_up_set?).to be true
    end

    it "leaves its strand alone when there is nothing to catch up on" do
      volume.record_host(host:, caught_up: true)
      expect(volume.reload.catch_up_set?).to be false
    end
  end

  describe "#key_material" do
    it "hands out the KEK and the wrapped data key" do
      expect(volume.key_material).to eq({"kek" => volume.key_encryption_key_1.key, "wrapped_xts" => volume.wrapped_xts})
    end

    it "is refused while the key is being rotated, so nothing starts on the old one" do
      volume.update(key_encryption_key_2_id: StorageKeyEncryptionKey.create_random(auth_data: "k2").id)
      expect { volume.key_material }.to raise_error(RuntimeError, "#{volume.ubid} is having its key rotated")
    end
  end

  describe "#stripe_source_for" do
    let(:host) { create_vm_host }

    it "seeds a new volume from the local image" do
      expect(volume.stripe_source_for(host)).to eq({"type" => "new", "image" => "ubuntu-noble"})
    end

    it "uses the local copy when the data is already on this host" do
      volume.update(vm_host_id: host.id)
      expect(volume.stripe_source_for(host)).to eq({"type" => "local"})
    end

    it "does not claim local data on a different host" do
      volume.update(vm_host_id: host.id)
      expect(volume.stripe_source_for(create_vm_host)).to be_nil
    end

    describe "while a move is being served" do
      let(:source) { create_vm_host }
      let(:server) {
        RemoteStorageServer.create(source_detachable_volume_id: volume.id, vm_host_id: source.id,
          psk: Base64.strict_encode64("p" * 32), psk_identity: "rs1", port: 5500)
      }

      before do
        Strand.create_with_id(server, prog: "Storage::RemoteStorageServer::Nexus", label: "wait")
        volume.update(vm_host_id: source.id)
      end

      it "lets another host take it over, reading from the server" do
        got = volume.stripe_source_for(host)
        expect(got).to include("type" => "remote", "address" => "#{source.sshable.host}:5500",
          "psk_identity" => "rs1", "autofetch" => true)
        expect(volume.key_encryption_key_1.decrypt(got["wrapped_psk"], "remote-psk")).to eq("p" * 32)
      end

      it "is not taken over until the server is serving" do
        server.strand.update(label: "start")
        expect(volume.stripe_source_for(host)).to be_nil
      end

      it "is not started again on the host it is being served from" do
        expect(volume.stripe_source_for(source)).to be_nil
      end

      it "belongs to the host that took it over, and to no other" do
        volume.update(vm_host_id: host.id)
        expect(volume.stripe_source_for(host)).to eq({"type" => "local"})
        expect(volume.stripe_source_for(create_vm_host)).to be_nil
      end
    end
  end

  describe "#start_move" do
    let(:source) { create_vm_host }

    before { VhostBlockBackend.create(vm_host_id: source.id, version_code: 501, allocation_weight: 0) }

    it "serves the volume from its host, so another host can take it over" do
      volume.update(vm_host_id: source.id)
      volume.start_move
      server = volume.reload.remote_storage_server
      expect(server.source_detachable_volume_id).to eq(volume.id)
      expect(server.vm_host_id).to eq(source.id)
      expect(server.strand.label).to eq("start")
    end

    it "refuses a volume that is not on a host" do
      expect { volume.start_move }.to raise_error(RuntimeError, "#{volume.ubid} is not on a host")
    end

    it "refuses a volume already being moved" do
      volume.update(vm_host_id: source.id)
      volume.start_move
      expect { volume.start_move }.to raise_error(RuntimeError, "#{volume.ubid} is already being moved")
    end
  end
end
