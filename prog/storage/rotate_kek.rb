# frozen_string_literal: true

require "json"

class Prog::Storage::RotateKek < Prog::Base
  subject_is :vm_storage_volume

  def self.assemble(vm_storage_volume_id)
    DB.transaction do
      # Lock the row so two rotations can't start at once.
      vm_storage_volume = VmStorageVolume.where(id: vm_storage_volume_id).for_update.first
      fail "storage volume not found" unless vm_storage_volume
      fail "storage volume is not encrypted" unless vm_storage_volume.key_encryption_key_1_id
      fail "a key rotation is already in progress" if vm_storage_volume.key_encryption_key_2_id
      # TODO: support config-v2 (TOML) volumes once TOML parsing is resolved.
      fail "config-v2 (TOML) storage KEK rotation is not supported yet" if vm_storage_volume.vhost_block_backend&.config_v2?

      key_encryption_key = StorageKeyEncryptionKey.create_random(auth_data: vm_storage_volume.device_id)
      vm_storage_volume.update(key_encryption_key_2_id: key_encryption_key.id)

      Strand.create_with_id(vm_storage_volume, prog: "Storage::RotateKek", label: "back_up_key")
    end
  end

  label def back_up_key
    register_deadline(nil, 10 * 60)
    host_tool("backup", {old_key: old_key_hash})

    hop_rotate
  end

  label def rotate
    host_tool("rotate", {old_key: old_key_hash, new_key: vm_storage_volume.key_encryption_key_2.secret_key_material_hash})

    hop_retire_old_key
  end

  label def retire_old_key
    # Delete the backup before swapping keys in the database, while key_1 is still
    # the old key so the host can name the backup file.
    host_tool("retire-backup", {old_key: old_key_hash})
    retired_key = vm_storage_volume.key_encryption_key_1
    vm_storage_volume.update({
      key_encryption_key_1_id: vm_storage_volume.key_encryption_key_2_id,
      key_encryption_key_2_id: nil,
    })
    retired_key.destroy

    pop "key rotated successfully"
  end

  def vm
    @vm ||= vm_storage_volume.vm
  end

  def sshable
    @sshable ||= vm.vm_host.sshable
  end

  private

  def host_tool(action, stdin)
    sshable.cmd("sudo host/bin/storage-key-tool :vm_name :disk_index :action",
      vm_name: vm.inhost_name, disk_index: vm_storage_volume.disk_index, action:, stdin: JSON.generate(stdin))
  end

  def old_key_hash
    @old_key_hash ||= vm_storage_volume.key_encryption_key_1.secret_key_material_hash
  end
end
