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
      volume.record_host(host:)
      expect(volume.reload.vm_host_id).to eq(host.id)
      expect(volume.catch_up_set?).to be false
    end

    it "has its strand watch a volume just taken over from the host serving it" do
      source = create_vm_host
      volume.update(vm_host_id: source.id)
      RemoteStorageServer.create(source_detachable_volume_id: volume.id, vm_host_id: source.id, psk: "cHNr", psk_identity: "rs1", port: 5500)
      volume.record_host(host:)
      expect(volume.reload.catch_up_set?).to be true
    end

    it "has nothing to catch up on when started again on the host that took it over" do
      volume.update(vm_host_id: host.id)
      RemoteStorageServer.create(source_detachable_volume_id: volume.id, vm_host_id: create_vm_host.id, psk: "cHNr", psk_identity: "rs1", port: 5500)
      volume.record_host(host:)
      expect(volume.reload.catch_up_set?).to be false
    end
  end

  describe "#caught_up?" do
    let(:host) { create_vm_host }

    before { volume.update(vm_host_id: host.id) }

    def expect_status(stripes)
      expect(volume.vm_host.sshable).to receive(:_cmd).with("sudo nc -U /var/storage/detachable/#{volume.ubid}/rpc.sock -q 2 -w 2 | head -n 1",
        stdin: {command: "status"}.to_json).and_return({"status" => {"stripes" => stripes}}.to_json)
    end

    it "asks the volume's ubiblk for its stripe counts" do
      expect_status({"fetched" => 8, "source" => 8})
      expect(volume).to be_caught_up
    end

    it "is not caught up while stripes are left to fetch" do
      expect_status({"fetched" => 3, "source" => 8})
      expect(volume).not_to be_caught_up
    end
  end

  describe "#start_params" do
    let(:host) { create_vm_host }

    def start_params(target_host)
      volume.start_params(target_host, unix_user: "user0", device_id: "dvdev", vhost_block_backend_version: "v0.5.1")
    end

    it "lays a new volume out from its seed image" do
      expect(start_params(host)).to eq({
        "unix_user" => "user0",
        "kek" => volume.key_encryption_key_1.secret_key_material_hash,
        "prep" => true,
        "storage_volume" => {
          "vhost_block_backend_version" => "v0.5.1",
          "encrypted" => true,
          "device_id" => "dvdev",
          "size_gib" => 2,
          "slice_name" => "system.slice",
          "queue_size" => 64,
          "track_written" => true,
          "copy_on_read" => true,
          "image" => "ubuntu-noble",
        },
      })
    end

    it "starts the data already on the host without laying it out again" do
      volume.update(vm_host_id: host.id)
      params = volume.start_params(host, unix_user: "user0", device_id: "dvdev", vhost_block_backend_version: "v0.5.1", slice_name: "example.slice")
      expect(params["prep"]).to be false
      expect(params["storage_volume"]).not_to include("image", "remote_source")
      expect(params["storage_volume"]["slice_name"]).to eq("example.slice")
    end

    it "does not start a volume whose data is on a different host" do
      volume.update(vm_host_id: host.id)
      expect(start_params(create_vm_host)).to be_nil
    end

    it "is refused while the key is being rotated, so nothing starts on the old one" do
      volume.update(key_encryption_key_2_id: StorageKeyEncryptionKey.create_random(auth_data: "k2").id)
      expect { start_params(host) }.to raise_error(RuntimeError, "#{volume.ubid} is having its key rotated")
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

      it "lets another host take it over, fetching from the server" do
        params = start_params(host)
        expect(params["prep"]).to be true
        remote = params["storage_volume"]["remote_source"]
        expect(remote).to include("address" => "#{source.sshable.host}:5500", "psk_identity" => "rs1", "autofetch" => true)
        wrapped = Base64.decode64(remote["encrypted_psk"])
        cipher = OpenSSL::Cipher.new("aes-256-gcm").decrypt
        cipher.key = Base64.decode64(volume.key_encryption_key_1.key)
        cipher.iv = wrapped[0, 12]
        cipher.auth_data = "remote-psk"
        cipher.auth_tag = wrapped[-16..]
        expect(cipher.update(wrapped[12...-16]) + cipher.final).to eq("p" * 32)
      end

      it "is not taken over until the server is serving" do
        server.strand.update(label: "start")
        expect(start_params(host)).to be_nil
      end

      it "is not started again on the host it is being served from" do
        expect(start_params(source)).to be_nil
      end

      it "belongs to the host that took it over, and to no other" do
        volume.update(vm_host_id: host.id)
        expect(start_params(host)["prep"]).to be false
        expect(start_params(create_vm_host)).to be_nil
      end
    end
  end
end
