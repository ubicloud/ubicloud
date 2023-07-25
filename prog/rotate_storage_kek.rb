# frozen_string_literal: true

require "shellwords"
require "json"

class Prog::RotateStorageKek < Prog::Base
  subject_is :vm_storage_volume

  label def start
    if vm_storage_volume.key_encryption_key_1_id.nil?
      pop "storage volume is not encrypted"
    end

    key_wrapping_algorithm = "aes-256-gcm"
    cipher = OpenSSL::Cipher.new(key_wrapping_algorithm)
    key_wrapping_key = cipher.random_key
    key_wrapping_iv = cipher.random_iv
    auth_data = vm_storage_volume.device_id

    DB.transaction do
      key_encryption_key = StorageKeyEncryptionKey.create(
        algorithm: key_wrapping_algorithm,
        key: Base64.encode64(key_wrapping_key),
        init_vector: Base64.encode64(key_wrapping_iv),
        auth_data: auth_data
      )

      vm_storage_volume.update({key_encryption_key_2_id: key_encryption_key.id})
    end

    hop_install
  end

  label def install
    data_json = JSON.generate({
      old_key: vm_storage_volume.key_encryption_key_1.secret_key_material_hash,
      new_key: vm_storage_volume.key_encryption_key_2.secret_key_material_hash
    })

    q_vm = vm.inhost_name.shellescape
    disk_index = vm_storage_volume.disk_index
    sshable.cmd("sudo bin/storage-key-tool #{q_vm} #{disk_index} reencrypt", stdin: data_json)

    hop_test_keys_on_server
  end

  label def test_keys_on_server
    data_json = JSON.generate({
      old_key: vm_storage_volume.key_encryption_key_1.secret_key_material_hash,
      new_key: vm_storage_volume.key_encryption_key_2.secret_key_material_hash
    })

    q_vm = vm.inhost_name.shellescape
    disk_index = vm_storage_volume.disk_index
    sshable.cmd("sudo bin/storage-key-tool #{q_vm} #{disk_index} test-keys", stdin: data_json)

    hop_retire_old_key_on_server
  end

  label def retire_old_key_on_server
    q_vm = vm.inhost_name.shellescape
    disk_index = vm_storage_volume.disk_index
    sshable.cmd("sudo bin/storage-key-tool #{q_vm} #{disk_index} retire-old-key", stdin: "{}")

    hop_retire_old_key_in_database
  end

  label def retire_old_key_in_database
    vm_storage_volume.update({
      key_encryption_key_1_id: vm_storage_volume.key_encryption_key_2_id,
      key_encryption_key_2_id: nil
    })

    pop "key rotated successfully"
  end

  def vm
    @vm ||= vm_storage_volume.vm
  end

  def sshable
    @sshable ||= vm.vm_host.sshable
  end
end
