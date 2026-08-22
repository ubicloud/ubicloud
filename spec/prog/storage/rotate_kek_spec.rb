# frozen_string_literal: true

require_relative "../../model/spec_helper"

RSpec.describe Prog::Storage::RotateKek do
  subject(:rsk) {
    described_class.new(Strand.new(prog: "Storage::RotateKek"))
  }

  let(:sshable) {
    Sshable.new
  }

  let(:vm) {
    vm_host = instance_double(VmHost)
    vm = Vm.new.tap {
      it.id = Vm.generate_uuid
    }
    allow(vm_host).to receive(:sshable).and_return(sshable)
    allow(vm).to receive(:vm_host).and_return(vm_host)
    vm
  }

  let(:current_kek) {
    StorageKeyEncryptionKey.create_with_id(
      StorageKeyEncryptionKey.generate_uuid,
      algorithm: "aes-256-gcm", key: "key_1",
      init_vector: "iv_1", auth_data: "somedata",
    )
  }

  let(:new_kek) {
    StorageKeyEncryptionKey.create_with_id(
      StorageKeyEncryptionKey.generate_uuid,
      algorithm: "aes-256-gcm", key: "key_2",
      init_vector: "iv_2", auth_data: "somedata",
    )
  }

  let(:volume) {
    dev = StorageDevice.create(
      name: "nvme0",
      total_storage_gib: 100,
      available_storage_gib: 20,
    ) { it.id = StorageDevice.generate_uuid }
    disk = VmStorageVolume.new(boot: true, size_gib: 20, disk_index: 0, storage_device: dev)
    disk.key_encryption_key_1 = current_kek
    disk.key_encryption_key_2 = new_kek
    disk.vm = vm
    disk
  }

  before do
    allow(rsk).to receive(:vm_storage_volume).and_return(volume)
  end

  describe ".assemble" do
    let(:storage_device) {
      StorageDevice.create(name: "nvme0", total_storage_gib: 100, available_storage_gib: 20)
    }

    def create_volume(key_1_id:, key_2_id: nil)
      VmStorageVolume.create(vm_id: create_vm.id, boot: true, size_gib: 20, disk_index: 0,
        use_bdev_ubi: false, storage_device_id: storage_device.id,
        key_encryption_key_1_id: key_1_id, key_encryption_key_2_id: key_2_id)
    end

    it "mints a second key and creates a strand that starts at back_up_key" do
      encryption_key = StorageKeyEncryptionKey.create_random(auth_data: "somedata")
      vol = create_volume(key_1_id: encryption_key.id)

      strand = nil
      expect { strand = described_class.assemble(vol.id) }.to change(StorageKeyEncryptionKey, :count).by(1)
      expect(strand.prog).to eq("Storage::RotateKek")
      expect(strand.label).to eq("back_up_key")
      expect(strand.stack.first["subject_id"]).to eq(vol.id)
      expect(vol.reload.key_encryption_key_2_id).not_to be_nil
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
  end

  describe "#back_up_key" do
    it "registers a deadline, backs up the old key on the host & hops" do
      expect(sshable).to receive(:_cmd).with(/sudo host\/bin\/rotate-storage-kek .* 0 backup/,
        stdin: "{\"old_key\":{\"key\":\"key_1\",\"init_vector\":\"iv_1\",\"algorithm\":\"aes-256-gcm\",\"auth_data\":\"somedata\"}}")
      expect { rsk.back_up_key }.to hop("rotate")
      expect(rsk.strand.stack[0]["deadline_at"]).not_to be_nil # rotation must finish or page
    end
  end

  describe "#rotate" do
    it "re-wraps the key on the host in one call & hops" do
      expect(sshable).to receive(:_cmd).with(/sudo host\/bin\/rotate-storage-kek .* 0 rotate/,
        stdin: "{\"old_key\":{\"key\":\"key_1\",\"init_vector\":\"iv_1\",\"algorithm\":\"aes-256-gcm\",\"auth_data\":\"somedata\"},\"new_key\":{\"key\":\"key_2\",\"init_vector\":\"iv_2\",\"algorithm\":\"aes-256-gcm\",\"auth_data\":\"somedata\"}}")
      expect { rsk.rotate }.to hop("retire_old_key")
    end
  end

  describe "#retire_old_key" do
    it "deletes the host backup, swaps the new key in, destroys the retired key, and pops" do
      expect(sshable).to receive(:_cmd).with(/sudo host\/bin\/rotate-storage-kek .* 0 retire-backup/,
        stdin: "{\"old_key\":{\"key\":\"key_1\",\"init_vector\":\"iv_1\",\"algorithm\":\"aes-256-gcm\",\"auth_data\":\"somedata\"}}")
      expect(volume).to receive(:update).with({key_encryption_key_1_id: new_kek.id, key_encryption_key_2_id: nil})
      expect { rsk.retire_old_key }.to exit({"msg" => "key rotated successfully"})
      expect(StorageKeyEncryptionKey[current_kek.id]).to be_nil # retired key material is gone from the db
    end
  end
end
