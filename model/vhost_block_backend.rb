# frozen_string_literal: true

require_relative "../model"

class VhostBlockBackend < Sequel::Model
  MIN_ARCHIVE_SUPPORT_VERSION = 400

  plugin ResourceMethods, etc_type: true

  def supports_archive?
    version_code >= MIN_ARCHIVE_SUPPORT_VERSION
  end

  def version
    major = version_code / 10000
    minor = (version_code % 10000) / 100
    patch = version_code % 100
    "v#{major}.#{minor}.#{patch}"
  end
end

# Table: vhost_block_backend
# Columns:
#  id                | uuid                     | PRIMARY KEY DEFAULT gen_random_ubid_uuid(474)
#  created_at        | timestamp with time zone | NOT NULL DEFAULT CURRENT_TIMESTAMP
#  version           | text                     | NOT NULL
#  allocation_weight | integer                  | NOT NULL
#  vm_host_id        | uuid                     | NOT NULL
#  version_code      | integer                  | NOT NULL
# Indexes:
#  vhost_block_backend_pkey                        | PRIMARY KEY btree (id)
#  vhost_block_backend_vm_host_id_version_code_key | UNIQUE btree (vm_host_id, version_code)
#  vhost_block_backend_vm_host_id_version_key      | UNIQUE btree (vm_host_id, version)
# Check constraints:
#  vhost_block_backend_allocation_weight_check | (allocation_weight >= 0)
# Foreign key constraints:
#  vhost_block_backend_vm_host_id_fkey | (vm_host_id) REFERENCES vm_host(id)
# Referenced By:
#  vm_storage_volume | vm_storage_volume_vhost_block_backend_id_fkey | (vhost_block_backend_id) REFERENCES vhost_block_backend(id)
