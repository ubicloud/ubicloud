# frozen_string_literal: true

require_relative "../../model/spec_helper"

RSpec.describe Prog::Storage::RotateKek do
  subject(:prog) {
    described_class.new(Strand.create(prog: "Storage::RotateKek", label: "back_up_key", stack: [{"subject_id" => volume.id}]))
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

    it "mints a second key labelled with the volume's id and starts a strand of its own at back_up_key" do
      vol = create_volume(key_1_id: StorageKeyEncryptionKey.create_random(auth_data: "somedata").id)

      strand = nil
      expect { strand = described_class.assemble(vol.id) }.to change(StorageKeyEncryptionKey, :count).by(1)
      expect(strand.prog).to eq("Storage::RotateKek")
      expect(strand.label).to eq("back_up_key")
      expect(strand.id).not_to eq(vol.id)
      expect(described_class.new(strand).volume.id).to eq(vol.id)
      expect(vol.reload.key_encryption_key_2.auth_data).to eq(vol.ubid)
    end

    it "sets the strand's parent when a parent_id is given" do
      parent = Strand.create(prog: "Vm::Nexus", label: "wait", stack: [{}])
      vol = create_volume(key_1_id: StorageKeyEncryptionKey.create_random(auth_data: "somedata").id)
      strand = described_class.assemble(vol.id, parent_id: parent.id)
      expect(strand.parent_id).to eq(parent.id)
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

  describe "a detachable volume" do
    let(:host) { create_vm_host }
    let(:dv) {
      Prog::Storage::DetachableVolumeNexus.assemble(project_id: Project.create(name: "p").id,
        location_id: Location::HETZNER_FSN1_ID, size_gib: 2, source_image: "seed-image")
    }
    let(:rotation) { described_class.new(described_class.assemble(dv.id)) }

    it "labels the second key with the volume's id, like its first, and rotates on a strand beside the volume's own" do
      strand = described_class.assemble(dv.id)
      expect(strand.id).not_to eq(dv.id)
      expect([dv.reload.key_encryption_key_1.auth_data, dv.key_encryption_key_2.auth_data]).to eq([dv.ubid, dv.ubid])
      expect(described_class.new(strand).volume.id).to eq(dv.id)
    end

    describe "laid out on a host" do
      before { dv.update(vm_host_id: host.id) }

      it "backs up, re-wraps and retires the key on the host through host/bin/detachable-volume-key-tool" do
        old_key = dv.key_encryption_key_1.secret_key_material_hash
        sshable = rotation.volume.vm_host.sshable
        new_key = dv.reload.key_encryption_key_2.secret_key_material_hash
        [["backup", {old_key:}], ["rotate", {old_key:, new_key:}], ["retire-backup", {old_key:}]].each do |action, stdin|
          expect(sshable).to receive(:_cmd).with("sudo host/bin/detachable-volume-key-tool #{dv.ubid} #{action}",
            stdin: JSON.generate(stdin)).ordered
        end
        expect { rotation.back_up_key }.to hop("rotate")
        expect { rotation.rotate }.to hop("retire_old_key")
        expect { rotation.retire_old_key }.to exit({"msg" => "key rotated successfully"})
      end
    end

    it "re-wraps the data key in the row with the new key and drops the old one" do
      old_kek = dv.key_encryption_key_1
      data_key = old_kek.decrypt(dv.wrapped_xts, "xts-key")
      rotation
      new_kek = dv.reload.key_encryption_key_2

      expect { rotation.retire_old_key }.to exit({"msg" => "key rotated successfully"})
      dv.reload
      expect(dv.key_encryption_key_1_id).to eq(new_kek.id)
      expect(dv.key_encryption_key_2_id).to be_nil
      expect(new_kek.decrypt(dv.wrapped_xts, "xts-key")).to eq(data_key)
      expect(old_kek).not_to exist
    end

    it "has nothing to do on a host for a volume that was never laid out" do
      expect(rotation.volume.vm_host).to be_nil
      expect { rotation.back_up_key }.to hop("rotate")
    end
  end
end
