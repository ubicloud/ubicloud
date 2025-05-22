# frozen_string_literal: true

require_relative "../model"

class SpdkInstallation < Sequel::Model
  many_to_one :vm_host
  one_to_many :vm_storage_volumes

  plugin ResourceMethods, etc_type: true

  def supports_bdev_ubi?
    # We version stock SPDK releases similar to v23.09, and add a ubi version
    # suffix if we package bdev_ubi along with it, similar to v23.09-ubi-0.1.
    version.match?(/^v[0-9]+\.[0-9]+-ubi-.*/)
  end
end

# Table: spdk_installation
# Columns:
#  id                | uuid                     | PRIMARY KEY
#  version           | text                     | NOT NULL
#  allocation_weight | integer                  | NOT NULL
#  created_at        | timestamp with time zone | NOT NULL DEFAULT now()
#  vm_host_id        | uuid                     |
#  cpu_count         | integer                  | NOT NULL DEFAULT 2
#  hugepages         | integer                  | NOT NULL DEFAULT 2
# Indexes:
#  spdk_installation_pkey                   | PRIMARY KEY btree (id)
#  spdk_installation_vm_host_id_version_key | UNIQUE btree (vm_host_id, version)
# Foreign key constraints:
#  spdk_installation_vm_host_id_fkey | (vm_host_id) REFERENCES vm_host(id)
# Referenced By:
#  vm_storage_volume | vm_storage_volume_spdk_installation_id_fkey | (spdk_installation_id) REFERENCES spdk_installation(id)
