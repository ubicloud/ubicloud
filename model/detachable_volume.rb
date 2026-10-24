# frozen_string_literal: true

require_relative "../model"

class DetachableVolume < Sequel::Model
  one_to_one :strand, key: :id
  many_to_one :project
  many_to_one :location
  many_to_one :vm_host
  many_to_one :key_encryption_key_1, class: :StorageKeyEncryptionKey
  many_to_one :key_encryption_key_2, class: :StorageKeyEncryptionKey, read_only: true
  one_to_one :remote_storage_server, key: :source_detachable_volume_id, read_only: true
  plugin :association_dependencies, key_encryption_key_1: :destroy, key_encryption_key_2: :destroy

  plugin ResourceMethods
  plugin SemaphoreMethods, :destroy, :catch_up

  # Records that the volume now lives on host. A volume just taken over from
  # the host serving it is still fetching its stripes from there.
  def record_host(host:)
    fetching = remote_storage_server && host.id != vm_host_id
    update(vm_host_id: host.id)
    incr_catch_up if fetching
  end

  def path
    File.join("/var/storage/detachable", ubid)
  end

  # Sends one command to the volume's ubiblk rpc socket. See
  # VmStorageVolume#rpc for the nc options.
  def rpc(payload)
    rpc_socket = File.join(path, "rpc.sock")
    vm_host.sshable.cmd_json("sudo nc -U :rpc_socket -q 2 -w 2 | head -n 1", stdin: payload.to_json, rpc_socket:)
  end

  def caught_up?
    stripes = rpc(command: "status").dig("status", "stripes")
    stripes.fetch("fetched") == stripes.fetch("source")
  end

  def self.wrap_xts(kek)
    kek.encrypt(SecureRandom.bytes(64), "xts-key")
  end

  # The input of host/bin/detachable-volume start, to start the volume on
  # target_host for a VM run by unix_user, with the storage volume in the
  # form StorageVolume takes it. nil if the volume can't start there now:
  # its data is on another host, or it is being served from this one.
  def start_params(target_host, unix_user:, device_id:, vhost_block_backend_version:, slice_name: "system.slice")
    fail "#{ubid} is having its key rotated" if key_encryption_key_2_id

    storage_volume = {
      "vhost_block_backend_version" => vhost_block_backend_version,
      "encrypted" => true,
      "device_id" => device_id,
      "size_gib" => size_gib,
      "slice_name" => slice_name,
      "queue_size" => 64,
      "track_written" => true,
      "copy_on_read" => true,
    }
    server = remote_storage_server
    prep = if vm_host_id.nil?
      storage_volume["image"] = source_image
      true
    elsif server && vm_host_id == server.vm_host_id
      return unless target_host.id != vm_host_id && server.strand.label == "wait"
      storage_volume["remote_source"] = remote_source(server)
      true
    elsif vm_host_id == target_host.id
      false
    else
      return
    end

    {
      "unix_user" => unix_user,
      "kek" => key_encryption_key_1.secret_key_material_hash,
      "prep" => prep,
      "storage_volume" => storage_volume,
    }
  end

  def remote_source(server)
    {
      "address" => server.address,
      "psk_identity" => server.psk_identity,
      "encrypted_psk" => key_encryption_key_1.encrypt(Base64.decode64(server.psk), "remote-psk"),
      "autofetch" => true,
    }
  end
end

# Table: detachable_volume
# Columns:
#  id                      | uuid                     | PRIMARY KEY DEFAULT gen_random_ubid_uuid(443)
#  created_at              | timestamp with time zone | NOT NULL DEFAULT CURRENT_TIMESTAMP
#  project_id              | uuid                     | NOT NULL
#  location_id             | uuid                     | NOT NULL
#  size_gib                | integer                  | NOT NULL
#  vm_host_id              | uuid                     |
#  key_encryption_key_1_id | uuid                     | NOT NULL
#  key_encryption_key_2_id | uuid                     |
#  wrapped_xts             | text                     | NOT NULL
#  source_image            | text                     | NOT NULL
# Indexes:
#  detachable_volume_pkey           | PRIMARY KEY btree (id)
#  detachable_volume_vm_host_id_idx | btree (vm_host_id)
# Foreign key constraints:
#  detachable_volume_key_encryption_key_1_id_fkey | (key_encryption_key_1_id) REFERENCES storage_key_encryption_key(id)
#  detachable_volume_key_encryption_key_2_id_fkey | (key_encryption_key_2_id) REFERENCES storage_key_encryption_key(id)
#  detachable_volume_location_id_fkey             | (location_id) REFERENCES location(id)
#  detachable_volume_project_id_fkey              | (project_id) REFERENCES project(id)
#  detachable_volume_vm_host_id_fkey              | (vm_host_id) REFERENCES vm_host(id)
# Referenced By:
#  remote_storage_server | remote_storage_server_source_detachable_volume_id_fkey | (source_detachable_volume_id) REFERENCES detachable_volume(id)
