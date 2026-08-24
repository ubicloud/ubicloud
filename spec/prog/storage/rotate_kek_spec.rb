# frozen_string_literal: true

require_relative "../../model/spec_helper"

RSpec.describe Prog::Storage::RotateKek do
  subject(:prog) {
    described_class.new(Strand.create_with_id(volume, prog: "Storage::RotateKek", label: "back_up_key"))
  }

  let(:storage_device) {
    StorageDevice.create(name: "nvme0", total_storage_gib: 100, available_storage_gib: 20)
  }
  let(:vm) { create_vm(vm_host_id: create_vm_host.id) }
  let(:current_kek) {
    StorageKeyEncryptionKey.create(algorithm: "aes-256-gcm", key: "key_1", init_vector: "iv_1", auth_data: "somedata")
  }
  let(:new_kek) {
    StorageKeyEncryptionKey.create(algorithm: "aes-256-gcm", key: "key_2", init_vector: "iv_2", auth_data: "somedata")
  }
  # A volume mid-rotation: key_1 is the old key, key_2 the freshly minted one.
  let(:volume) {
    VmStorageVolume.create(vm_id: vm.id, boot: true, size_gib: 20, disk_index: 0,
      use_bdev_ubi: false, storage_device_id: storage_device.id,
      key_encryption_key_1_id: current_kek.id, key_encryption_key_2_id: new_kek.id)
  }

  describe ".assemble" do
    def create_volume(key_1_id:, key_2_id: nil, **args)
      VmStorageVolume.create(vm_id: create_vm.id, boot: true, size_gib: 20, disk_index: 0,
        use_bdev_ubi: false, storage_device_id: storage_device.id,
        key_encryption_key_1_id: key_1_id, key_encryption_key_2_id: key_2_id, **args)
    end

    it "mints a second key bound to the device and starts a strand at back_up_key" do
      vol = create_volume(key_1_id: StorageKeyEncryptionKey.create_random(auth_data: "somedata").id)

      strand = nil
      expect { strand = described_class.assemble(vol.id) }.to change(StorageKeyEncryptionKey, :count).by(1)
      expect(strand.prog).to eq("Storage::RotateKek")
      expect(strand.label).to eq("back_up_key")
      expect(strand.id).to eq(vol.id)
      expect(vol.reload.key_encryption_key_2.auth_data).to eq(vol.device_id)
    end

    it "fails when the volume does not exist" do
      expect { described_class.assemble(VmStorageVolume.generate_uuid) }.to raise_error("storage volume not found")
    end

    it "fails when the volume is not encrypted" do
      vol = create_volume(key_1_id: nil)
      expect { described_class.assemble(vol.id) }.to raise_error("storage volume is not encrypted")
    end

    it "fails when a rotation is already in progress" do
      vol = create_volume(key_1_id: StorageKeyEncryptionKey.create_random(auth_data: "k1").id,
        key_2_id: StorageKeyEncryptionKey.create_random(auth_data: "k2").id)
      expect { described_class.assemble(vol.id) }.to raise_error("a key rotation is already in progress")
    end

    it "fails for a config-v2 (TOML) volume, which is not supported yet" do
      backend = create_vhost_block_backend(version: "v0.4.0")
      vol = create_volume(key_1_id: StorageKeyEncryptionKey.create_random(auth_data: "k").id,
        vhost_block_backend_id: backend.id, vring_workers: 1)
      expect { described_class.assemble(vol.id) }.to raise_error("config-v2 (TOML) storage KEK rotation is not supported yet")
    end
  end

  describe "#back_up_key" do
    it "registers a deadline, backs up the old key on the host, and hops" do
      expect(prog.sshable).to receive(:_cmd).with("sudo host/bin/storage-key-tool #{vm.inhost_name} 0 backup",
        stdin: "{\"old_key\":{\"key\":\"key_1\",\"init_vector\":\"iv_1\",\"algorithm\":\"aes-256-gcm\",\"auth_data\":\"somedata\"}}")
      expect { prog.back_up_key }.to hop("rotate")
      expect(prog.strand.stack[0]["deadline_at"]).not_to be_nil # rotation must finish or page
    end
  end

  describe "#rotate" do
    it "re-wraps the key on the host in one call and hops" do
      expect(prog.sshable).to receive(:_cmd).with("sudo host/bin/storage-key-tool #{vm.inhost_name} 0 rotate",
        stdin: "{\"old_key\":{\"key\":\"key_1\",\"init_vector\":\"iv_1\",\"algorithm\":\"aes-256-gcm\",\"auth_data\":\"somedata\"},\"new_key\":{\"key\":\"key_2\",\"init_vector\":\"iv_2\",\"algorithm\":\"aes-256-gcm\",\"auth_data\":\"somedata\"}}")
      expect { prog.rotate }.to hop("retire_old_key")
    end
  end

  describe "#retire_old_key" do
    it "deletes the host backup, swaps the new key into the database, destroys the retired key, and pops" do
      expect(prog.sshable).to receive(:_cmd).with("sudo host/bin/storage-key-tool #{vm.inhost_name} 0 retire-backup",
        stdin: "{\"old_key\":{\"key\":\"key_1\",\"init_vector\":\"iv_1\",\"algorithm\":\"aes-256-gcm\",\"auth_data\":\"somedata\"}}")
      expect { prog.retire_old_key }.to exit({"msg" => "key rotated successfully"})

      # The old key is swapped out only after nothing references it, so the
      # foreign key stays satisfied and the retired key row is gone.
      expect(volume.reload.key_encryption_key_1_id).to eq(new_kek.id)
      expect(volume.key_encryption_key_2_id).to be_nil
      expect(current_kek).not_to exist
    end
  end
end
