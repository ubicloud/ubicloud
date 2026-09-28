# frozen_string_literal: true

require "json"

class Prog::Storage::RotateKek < Prog::Base
  def self.assemble(volume_id, parent_id: nil)
    DB.transaction do
      # Lock the row so two rotations can't start at once.
      volume = VmStorageVolume.for_update.first(id: volume_id) ||
        DetachableVolume.for_update.first(id: volume_id)
      fail "storage volume not found" unless volume
      fail "storage volume is not encrypted" unless volume.key_encryption_key_1_id
      fail "a key rotation is already in progress" if volume.key_encryption_key_2_id

      key_encryption_key = StorageKeyEncryptionKey.create_random(auth_data: volume.ubid)
      volume.update(key_encryption_key_2_id: key_encryption_key.id)

      Strand.create(prog: "Storage::RotateKek", label: "back_up_key", parent_id:, stack: [{"subject_id" => volume.id}])
    end
  end

  label def back_up_key
    register_deadline(nil, 10 * 60)
    host_tool("backup", {old_key: old_key_hash})

    hop_rotate
  end

  label def rotate
    host_tool("rotate", {old_key: old_key_hash, new_key: volume.key_encryption_key_2.secret_key_material_hash})

    hop_retire_old_key
  end

  label def retire_old_key
    # Delete the backup before swapping keys in the database, while key_1 is still
    # the old key so the host can name the backup file.
    host_tool("retire-backup", {old_key: old_key_hash})
    retired_key = volume.key_encryption_key_1
    changes = {
      key_encryption_key_1_id: volume.key_encryption_key_2_id,
      key_encryption_key_2_id: nil,
    }
    if volume.is_a?(DetachableVolume)
      changes[:wrapped_xts] = volume.key_encryption_key_2.encrypt(retired_key.decrypt(volume.wrapped_xts, "xts-key"), "xts-key")
    end
    volume.update(changes)
    retired_key.destroy

    pop "key rotated successfully"
  end

  def volume
    @volume ||= VmStorageVolume[@subject_id] || DetachableVolume[@subject_id]
  end

  def vm
    @vm ||= volume.vm
  end

  def sshable
    @sshable ||= vm.vm_host.sshable
  end

  private

  def host_tool(action, stdin)
    if volume.is_a?(VmStorageVolume)
      sshable.cmd("sudo host/bin/storage-key-tool :vm_name :disk_index :action",
        vm_name: vm.inhost_name, disk_index: volume.disk_index, action:, stdin: JSON.generate(stdin))
    elsif (host = volume.vm_host)
      # A volume that has never been laid out has nothing on a host to re-wrap.
      host.sshable.cmd("sudo host/bin/detachable-volume-key-tool :volume_id :action",
        volume_id: volume.ubid, action:, stdin: JSON.generate(stdin))
    end
  end

  def old_key_hash
    @old_key_hash ||= volume.key_encryption_key_1.secret_key_material_hash
  end
end
