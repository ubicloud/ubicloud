# frozen_string_literal: true

require_relative "../model"

class VmStorageVolume < Sequel::Model
  many_to_one :vm
  many_to_one :spdk_installation
  many_to_one :storage_device
  many_to_one :key_encryption_key_1, class: :StorageKeyEncryptionKey
  many_to_one :key_encryption_key_2, class: :StorageKeyEncryptionKey
  many_to_one :boot_image

  plugin :association_dependencies, key_encryption_key_1: :destroy, key_encryption_key_2: :destroy

  plugin ResourceMethods

  def device_id
    "#{vm.inhost_name}_#{disk_index}"
  end

  def device_path
    (vm.location.provider == "aws") ? "/dev/nvme1n1" : "/dev/disk/by-id/virtio-#{device_id}"
  end

  def spdk_version
    spdk_installation.version
  end
end

# Table: vm_storage_volume
# Columns:
#  id                       | uuid    | PRIMARY KEY
#  vm_id                    | uuid    | NOT NULL
#  boot                     | boolean | NOT NULL
#  size_gib                 | bigint  | NOT NULL
#  disk_index               | integer | NOT NULL
#  key_encryption_key_1_id  | uuid    |
#  key_encryption_key_2_id  | uuid    |
#  spdk_installation_id     | uuid    |
#  use_bdev_ubi             | boolean | NOT NULL DEFAULT false
#  skip_sync                | boolean | NOT NULL DEFAULT false
#  storage_device_id        | uuid    |
#  boot_image_id            | uuid    |
#  max_ios_per_sec          | integer |
#  max_read_mbytes_per_sec  | integer |
#  max_write_mbytes_per_sec | integer |
# Indexes:
#  vm_storage_volume_pkey                 | PRIMARY KEY btree (id)
#  vm_storage_volume_vm_id_disk_index_key | UNIQUE btree (vm_id, disk_index)
# Foreign key constraints:
#  vm_storage_volume_boot_image_id_fkey           | (boot_image_id) REFERENCES boot_image(id)
#  vm_storage_volume_key_encryption_key_1_id_fkey | (key_encryption_key_1_id) REFERENCES storage_key_encryption_key(id)
#  vm_storage_volume_key_encryption_key_2_id_fkey | (key_encryption_key_2_id) REFERENCES storage_key_encryption_key(id)
#  vm_storage_volume_spdk_installation_id_fkey    | (spdk_installation_id) REFERENCES spdk_installation(id)
#  vm_storage_volume_storage_device_id_fkey       | (storage_device_id) REFERENCES storage_device(id)
#  vm_storage_volume_vm_id_fkey                   | (vm_id) REFERENCES vm(id)
