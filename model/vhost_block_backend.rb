# frozen_string_literal: true

require_relative "../model"

class VhostBlockBackend < Sequel::Model
  MIN_ARCHIVE_SUPPORT_VERSION = 401
  MIN_DUMP_METADATA_SUPPORT_VERSION = 400

  # Source of truth for which ubiblk release binaries we know about. Keep
  # this in sync with the matching constant in rhizome/host/lib/vhost_block_backend.rb,
  # which uses symbol arches because that side calls Arch.sym.
  SHA256_BY_VERSION_AND_ARCH = {
    ["v0.4.2", "x64"] => "e7e430f2e722a2d5d7c18a4f609360e003798d481e26da6db380e698ccb079eb",
    ["v0.4.2", "arm64"] => "ada92fe076e49f731f5d343d445b1e80d7685b811c33cde7fe88918e93649093",
    ["v0.3.1", "x64"] => "3b4a6d3387a8da7c914d85203955c0a879168518aed76679a334070403630262",
    ["v0.3.1", "arm64"] => "d7cd297468569a0fa197d48eb7d21b64aea9598895d1b5b97da8bec5e307d57b",
    ["v0.2.2", "x64"] => "f5b7b2b88fa18e5070ff319b15363aed671e496d9f6cccec3bbcc48a6f38a44a",
    ["v0.2.2", "arm64"] => "7f4a5818fdab4e7524855096352d9ceaa038ff254de2b52c88d491f76a05686f",
  }.freeze
  SHA256_BY_VERSION_AND_ARCH.each_key(&:freeze)

  plugin ResourceMethods, etc_type: true

  def version
    major = version_code / 10000
    minor = (version_code % 10000) / 100
    patch = version_code % 100
    "v#{major}.#{minor}.#{patch}"
  end

  def version=(version_str)
    v = Gem::Version.new(version_str.delete_prefix("v")).segments
    self.version_code = v[0] * 10000 + v[1] * 100 + v[2]
  end

  def supports_dump_metadata?
    version_code >= MIN_DUMP_METADATA_SUPPORT_VERSION
  end
end

# Table: vhost_block_backend
# Columns:
#  id                | uuid                     | PRIMARY KEY DEFAULT gen_random_ubid_uuid(474)
#  created_at        | timestamp with time zone | NOT NULL DEFAULT CURRENT_TIMESTAMP
#  allocation_weight | integer                  | NOT NULL
#  vm_host_id        | uuid                     | NOT NULL
#  version_code      | integer                  | NOT NULL
# Indexes:
#  vhost_block_backend_pkey                        | PRIMARY KEY btree (id)
#  vhost_block_backend_vm_host_id_version_code_key | UNIQUE btree (vm_host_id, version_code)
# Check constraints:
#  vhost_block_backend_allocation_weight_check | (allocation_weight >= 0)
# Foreign key constraints:
#  vhost_block_backend_vm_host_id_fkey | (vm_host_id) REFERENCES vm_host(id)
# Referenced By:
#  vm_storage_volume | vm_storage_volume_vhost_block_backend_id_fkey | (vhost_block_backend_id) REFERENCES vhost_block_backend(id)
