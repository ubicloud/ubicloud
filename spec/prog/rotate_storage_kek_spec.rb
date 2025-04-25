# frozen_string_literal: true

require_relative "../model/spec_helper"

RSpec.describe Prog::RotateStorageKek do
  subject(:rsk) {
    described_class.new(Strand.new(prog: "RotateStorageKek"))
  }

  let(:sshable) {
    instance_double(Sshable)
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
    StorageKeyEncryptionKey.new(
      algorithm: "aes-256-gcm", key: "key_1",
      init_vector: "iv_1", auth_data: "somedata"
    ) { it.id = StorageKeyEncryptionKey.generate_uuid }
  }

  let(:new_kek) {
    StorageKeyEncryptionKey.new(
      algorithm: "aes-256-gcm", key: "key_2",
      init_vector: "iv_2", auth_data: "somedata"
    ) { it.id = StorageKeyEncryptionKey.generate_uuid }
  }

  let(:volume) {
    dev = StorageDevice.create(
      name: "nvme0",
      total_storage_gib: 100,
      available_storage_gib: 20
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

  describe "#start" do
    it "creates a key & hops to install" do
      expect(StorageKeyEncryptionKey).to receive(:create).and_return(current_kek)
      expect(volume).to receive(:update).with({key_encryption_key_2_id: current_kek.id})
      expect { rsk.start }.to hop("install")
    end

    it "pops if not encrypted volume" do
      unencrypted_volume = instance_double(VmStorageVolume)
      expect(unencrypted_volume).to receive(:key_encryption_key_1_id).and_return(nil)
      expect(rsk).to receive(:vm_storage_volume).and_return(unencrypted_volume)
      expect { rsk.start }.to exit({"msg" => "storage volume is not encrypted"})
    end
  end

  describe "#install" do
    it "installs the key & hops" do
      expect(sshable).to receive(:cmd).with(/sudo host\/bin\/storage-key-tool .* nvme0 0 reencrypt/,
        stdin: "{\"old_key\":{\"key\":\"key_1\",\"init_vector\":\"iv_1\",\"algorithm\":\"aes-256-gcm\",\"auth_data\":\"somedata\"},\"new_key\":{\"key\":\"key_2\",\"init_vector\":\"iv_2\",\"algorithm\":\"aes-256-gcm\",\"auth_data\":\"somedata\"}}")
      expect { rsk.install }.to hop("test_keys_on_server")
    end
  end

  describe "#test_keys_on_server" do
    it "can test keys on server" do
      expect(sshable).to receive(:cmd).with(/sudo host\/bin\/storage-key-tool .* nvme0 0 test-keys/, stdin: /.*/)
      expect { rsk.test_keys_on_server }.to hop("retire_old_key_on_server")
    end
  end

  describe "#retire_old_key_on_server" do
    it "can retire old keys on server" do
      expect(sshable).to receive(:cmd).with(/sudo host\/bin\/storage-key-tool .* nvme0 0 retire-old-key/, stdin: "{}")
      expect { rsk.retire_old_key_on_server }.to hop("retire_old_key_in_database")
    end
  end

  describe "#retire_old_key_in_database" do
    it "can retire old keys on database" do
      expect(volume).to receive(:update).with({key_encryption_key_1_id: new_kek.id, key_encryption_key_2_id: nil})
      expect { rsk.retire_old_key_in_database }.to exit({"msg" => "key rotated successfully"})
    end
  end
end
