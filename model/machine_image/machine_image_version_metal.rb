# frozen_string_literal: true

require_relative "../../model"

class MachineImageVersionMetal < Sequel::Model
  many_to_one :machine_image_version, key: :id, read_only: true, is_used: true
  many_to_one :store, class: :MachineImageStore, read_only: true
  many_to_one :archive_kek, class: :StorageKeyEncryptionKey, read_only: true
  one_to_many :vm_storage_volumes, key: :machine_image_version_id, read_only: true
  one_to_many :active_billing_records, class: :BillingRecord, key: :resource_id, read_only: true, &:active

  plugin ResourceMethods, referencing: UBID::TYPE_MACHINE_IMAGE_VERSION

  def display_state
    return "ready" if enabled
    archive_size_mib ? "destroying" : "creating"
  end

  def create_billing_record
    miv = machine_image_version
    mi = miv.machine_image
    project = mi.project
    return unless project.billable
    BillingRecord.create(
      project_id: project.id,
      resource_id: id,
      resource_name: "#{mi.name}:#{miv.version}",
      billing_rate_id: BillingRate.from_resource_properties("MachineImageStorage", "standard", mi.location.name)["id"],
      amount: archive_size_mib / 1024.0,
    )
  end
end

# Table: machine_image_version_metal
# Columns:
#  id               | uuid    | PRIMARY KEY
#  enabled          | boolean | NOT NULL DEFAULT false
#  archive_size_mib | integer |
#  archive_kek_id   | uuid    | NOT NULL
#  store_id         | uuid    | NOT NULL
#  store_prefix     | text    | NOT NULL
#  status           | text    | NOT NULL
# Indexes:
#  machine_image_version_metal_pkey | PRIMARY KEY btree (id)
# Check constraints:
#  archive_size_set_if_status_ready         | (status <> 'ready'::text OR archive_size_mib IS NOT NULL)
#  machine_image_version_metal_status_check | (status = ANY (ARRAY['creating'::text, 'ready'::text, 'destroying'::text]))
#  size_set_if_enabled                      | (NOT enabled OR archive_size_mib IS NOT NULL)
# Foreign key constraints:
#  machine_image_version_metal_archive_kek_id_fkey | (archive_kek_id) REFERENCES storage_key_encryption_key(id)
#  machine_image_version_metal_id_fkey             | (id) REFERENCES machine_image_version(id)
#  machine_image_version_metal_store_id_fkey       | (store_id) REFERENCES machine_image_store(id)
