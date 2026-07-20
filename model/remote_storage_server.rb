# frozen_string_literal: true

require_relative "../model"

# Serves a single VmStorageVolume over the ubiblk remote stripe protocol
# (TLS-PSK) so another host can boot a VM whose stripe source is this server.
class RemoteStorageServer < Sequel::Model
  one_to_one :strand, key: :id
  many_to_one :source_vm_storage_volume, class: :VmStorageVolume

  plugin ResourceMethods, encrypted_columns: :psk
  plugin SemaphoreMethods, :destroy, :checkup

  def vm
    source_vm_storage_volume.vm
  end

  def vm_host
    vm.vm_host
  end

  # Address a client connects to over the remote stripe protocol.
  def address
    "#{vm_host.sshable.host}:#{port}"
  end
end

# Table: remote_storage_server
# Columns:
#  id                          | uuid                     | PRIMARY KEY
#  created_at                  | timestamp with time zone | NOT NULL DEFAULT now()
#  psk                         | text                     | NOT NULL
#  psk_identity                | text                     | NOT NULL
#  port                        | integer                  | NOT NULL
#  source_vm_storage_volume_id | uuid                     | NOT NULL
# Indexes:
#  remote_storage_server_pkey | PRIMARY KEY btree (id)
# Foreign key constraints:
#  remote_storage_server_source_vm_storage_volume_id_fkey | (source_vm_storage_volume_id) REFERENCES vm_storage_volume(id)
# Referenced By:
#  vm_storage_volume | vm_storage_volume_remote_storage_server_id_fkey | (remote_storage_server_id) REFERENCES remote_storage_server(id)
