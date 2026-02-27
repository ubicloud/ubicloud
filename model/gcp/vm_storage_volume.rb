# frozen_string_literal: true

class VmStorageVolume < Sequel::Model
  module Gcp
    private

    def gcp_device_path
      # Standard VMs with 4+ vCPUs use LSSD machine types that bundle
      # local NVMe SSDs. Burstable and 2-vCPU standard VMs use e2 types
      # with persistent disks only.
      if !boot && vm.family != "burstable" && vm.vcpus >= 4
        "/dev/disk/by-id/google-local-nvme-ssd-#{disk_index - 1}"
      else
        "/dev/disk/by-id/google-persistent-disk-#{disk_index}"
      end
    end
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
#  max_read_mbytes_per_sec  | integer |
#  max_write_mbytes_per_sec | integer |
#  vhost_block_backend_id   | uuid    |
#  vring_workers            | integer |
# Indexes:
#  vm_storage_volume_pkey                 | PRIMARY KEY btree (id)
#  vm_storage_volume_vm_id_disk_index_key | UNIQUE btree (vm_id, disk_index)
# Check constraints:
#  vring_workers_null_if_not_ubiblk | (vhost_block_backend_id IS NOT NULL OR vring_workers IS NULL)
#  vring_workers_positive_if_ubiblk | (vhost_block_backend_id IS NULL OR vring_workers IS NOT NULL AND vring_workers > 0)
# Foreign key constraints:
#  vm_storage_volume_boot_image_id_fkey           | (boot_image_id) REFERENCES boot_image(id)
#  vm_storage_volume_key_encryption_key_1_id_fkey | (key_encryption_key_1_id) REFERENCES storage_key_encryption_key(id)
#  vm_storage_volume_key_encryption_key_2_id_fkey | (key_encryption_key_2_id) REFERENCES storage_key_encryption_key(id)
#  vm_storage_volume_spdk_installation_id_fkey    | (spdk_installation_id) REFERENCES spdk_installation(id)
#  vm_storage_volume_storage_device_id_fkey       | (storage_device_id) REFERENCES storage_device(id)
#  vm_storage_volume_vhost_block_backend_id_fkey  | (vhost_block_backend_id) REFERENCES vhost_block_backend(id)
#  vm_storage_volume_vm_id_fkey                   | (vm_id) REFERENCES vm(id)
