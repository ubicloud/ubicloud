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
end
