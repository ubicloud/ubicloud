# frozen_string_literal: true

require_relative "../model"

# Serves a single VmStorageVolume or DetachableVolume over the ubiblk remote
# stripe protocol (TLS-PSK) so another host can take the volume over, reading
# its stripes from this server until it has them all.
class RemoteStorageServer < Sequel::Model
  one_to_one :strand, key: :id
  many_to_one :source_vm_storage_volume, class: :VmStorageVolume, read_only: true
  many_to_one :source_detachable_volume, class: :DetachableVolume, read_only: true
  many_to_one :host, class: :VmHost, key: :vm_host_id, read_only: true

  plugin ResourceMethods, encrypted_columns: :psk
  plugin SemaphoreMethods, :destroy, :checkup

  def vm
    source_vm_storage_volume.vm
  end

  # A detachable volume's own host changes once it is started elsewhere, so
  # the server keeps the host it serves from.
  def vm_host
    source_vm_storage_volume_id ? vm.vm_host : host
  end

  # Address a client connects to over the remote stripe protocol.
  def address
    "#{vm_host.sshable.host}:#{port}"
  end

  # Byte size of the source volume's disk.raw, read live over SSH, so a MoveVm
  # target can size its own disk.raw to hold a (possibly oversized) source.
  def source_disk_file_size
    disk_file = File.join(source_vm_storage_volume.path, "disk.raw")
    Integer(vm_host.sshable.cmd("sudo stat -c %s :disk_file", disk_file:).strip, 10)
  end
end

# Table: remote_storage_server
# Columns:
#  id                          | uuid                     | PRIMARY KEY DEFAULT gen_random_ubid_uuid(793)
#  created_at                  | timestamp with time zone | NOT NULL DEFAULT CURRENT_TIMESTAMP
#  psk                         | text                     | NOT NULL
#  psk_identity                | text                     | NOT NULL
#  port                        | integer                  | NOT NULL
#  source_vm_storage_volume_id | uuid                     |
#  vm_host_id                  | uuid                     | NOT NULL
#  source_detachable_volume_id | uuid                     |
# Indexes:
#  remote_storage_server_pkey                            | PRIMARY KEY btree (id)
#  remote_storage_server_source_detachable_volume_id_key | UNIQUE btree (source_detachable_volume_id)
#  remote_storage_server_vm_host_id_port_uidx            | UNIQUE btree (vm_host_id, port)
# Check constraints:
#  remote_storage_server_single_source | (((source_vm_storage_volume_id IS NOT NULL)::integer + (source_detachable_volume_id IS NOT NULL)::integer) = 1)
# Foreign key constraints:
#  remote_storage_server_source_detachable_volume_id_fkey | (source_detachable_volume_id) REFERENCES detachable_volume(id)
#  remote_storage_server_source_vm_storage_volume_id_fkey | (source_vm_storage_volume_id) REFERENCES vm_storage_volume(id)
#  remote_storage_server_vm_host_id_fkey                  | (vm_host_id) REFERENCES vm_host(id)
# Referenced By:
#  vm_storage_volume | vm_storage_volume_remote_storage_server_id_fkey | (remote_storage_server_id) REFERENCES remote_storage_server(id)
