# frozen_string_literal: true

require_relative "../model"
require "json"

class VmStorageVolume < Sequel::Model
  many_to_one :vm
  many_to_one :spdk_installation, read_only: true
  many_to_one :vhost_block_backend, read_only: true
  many_to_one :storage_device
  many_to_one :key_encryption_key_1, class: :StorageKeyEncryptionKey
  many_to_one :key_encryption_key_2, class: :StorageKeyEncryptionKey
  many_to_one :boot_image, read_only: true
  many_to_one :machine_image_version, read_only: true

  plugin :association_dependencies, key_encryption_key_1: :destroy, key_encryption_key_2: :destroy

  plugin ResourceMethods
  plugin ProviderDispatcher, __FILE__

  def provider_dispatcher_group_name
    vm.location.provider_dispatcher_group_name
  end

  def vhost_backend_systemd_unit_name
    "#{vm.inhost_name}-#{disk_index}-storage.service"
  end

  def device_id
    "#{vm.inhost_name}_#{disk_index}"
  end

  def spdk_version
    spdk_installation&.version
  end

  def vhost_block_backend_version
    vhost_block_backend&.version
  end

  def num_queues
    @num_queues ||= if vhost_block_backend
      vring_workers
    else
      # SPDK volumes
      1
    end
  end

  def queue_size
    @queue_size ||= if vhost_block_backend
      64
    else
      # SPDK volumes
      256
    end
  end

  def path
    @path ||= File.join(storage_device.path, vm.inhost_name, disk_index.to_s)
  end

  def rpc(payload)
    # The rpc server sends each response in a separate line. The pipe through
    # `head -n 1` is to close the connection after receiving the first response,
    # otherwise the rpc server will keep the connection open waiting for the 2nd
    # request, until the timeout is reached.
    #
    # `-q 2`: after stdin EOF, wait up to 2s for the response before exiting
    # `-w 2`: connection timeout
    rpc_socket = File.join(path, "rpc.sock")
    vm.vm_host.sshable.cmd_json("sudo nc -U :rpc_socket -q 2 -w 2 | head -n 1", stdin: payload.to_json, rpc_socket:)
  end

  def caught_up?
    stripes = rpc(command: "status").dig("status", "stripes")
    stripes.fetch("fetched") == stripes.fetch("source")
  end

  def dump_metadata
    fail "dump_metadata only supported for vm storage volumes with vhost block backend version v0.4.0+" unless vhost_block_backend&.supports_dump_metadata?
    fail "dump_metadata requires an encrypted vm storage volume" unless key_encryption_key_1

    vm.vm_host.sshable.cmd(
      "sudo host/bin/storage-dump-metadata :vm_name :storage_device :disk_index :vhost_block_backend_version",
      vm_name: vm.inhost_name,
      storage_device: storage_device.name,
      disk_index:,
      vhost_block_backend_version:,
      stdin: key_encryption_key_1.secret_key_material_hash.to_json,
    )
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
#  storage_device_id        | uuid    |
#  boot_image_id            | uuid    |
#  max_read_mbytes_per_sec  | integer |
#  max_write_mbytes_per_sec | integer |
#  vhost_block_backend_id   | uuid    |
#  vring_workers            | integer |
#  machine_image_version_id | uuid    |
#  track_written            | boolean | NOT NULL DEFAULT false
# Indexes:
#  vm_storage_volume_pkey                 | PRIMARY KEY btree (id)
#  vm_storage_volume_vm_id_disk_index_key | UNIQUE btree (vm_id, disk_index)
# Check constraints:
#  vm_storage_volume_single_source  | (boot_image_id IS NULL OR machine_image_version_id IS NULL)
#  vring_workers_null_if_not_ubiblk | (vhost_block_backend_id IS NOT NULL OR vring_workers IS NULL)
#  vring_workers_positive_if_ubiblk | (vhost_block_backend_id IS NULL OR vring_workers IS NOT NULL AND vring_workers > 0)
# Foreign key constraints:
#  vm_storage_volume_boot_image_id_fkey            | (boot_image_id) REFERENCES boot_image(id)
#  vm_storage_volume_key_encryption_key_1_id_fkey  | (key_encryption_key_1_id) REFERENCES storage_key_encryption_key(id)
#  vm_storage_volume_key_encryption_key_2_id_fkey  | (key_encryption_key_2_id) REFERENCES storage_key_encryption_key(id)
#  vm_storage_volume_machine_image_version_id_fkey | (machine_image_version_id) REFERENCES machine_image_version(id)
#  vm_storage_volume_spdk_installation_id_fkey     | (spdk_installation_id) REFERENCES spdk_installation(id)
#  vm_storage_volume_storage_device_id_fkey        | (storage_device_id) REFERENCES storage_device(id)
#  vm_storage_volume_vhost_block_backend_id_fkey   | (vhost_block_backend_id) REFERENCES vhost_block_backend(id)
#  vm_storage_volume_vm_id_fkey                    | (vm_id) REFERENCES vm(id)
