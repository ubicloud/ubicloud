# frozen_string_literal: true

require_relative "../model"

class VmStorageVolume < Sequel::Model
  many_to_one :vm
  many_to_one :key_encryption_key_1, class: :StorageKeyEncryptionKey
  many_to_one :key_encryption_key_2, class: :StorageKeyEncryptionKey

  plugin :association_dependencies, key_encryption_key_1: :destroy, key_encryption_key_2: :destroy

  include ResourceMethods

  def device_id
    "#{vm.inhost_name}_#{disk_index}"
  end

  def device_path
    "/dev/disk/by-id/virtio-#{device_id}"
  end

  def params_hash
    {
      "boot" => boot,
      "image" => boot ? vm.boot_image : nil,
      "size_gib" => size_gib,
      "device_id" => device_id,
      "disk_index" => disk_index,
      "encrypted" => !key_encryption_key_1.nil?,
      "vm_inhost_name" => Vm.uuid_to_name(vm_id)
    }
  end

  def self.storage_secrets_hash(storage_volumes_dataset)
    storage_volumes_dataset.filter_map { |s|
      if !s.key_encryption_key_1.nil?
        [s.device_id, s.key_encryption_key_1.secret_key_material_hash]
      end
    }.to_h
  end
end
