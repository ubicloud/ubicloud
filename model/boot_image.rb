# frozen_string_literal: true

require_relative "../model"

class BootImage < Sequel::Model
  many_to_one :vm_host, key: :vm_host_id, class: :VmHost
  one_to_many :vm_storage_volumes, key: :boot_image_id, class: :VmStorageVolume

  plugin ResourceMethods, etc_type: true

  # Introduced for removing a boot image via REPL.
  def remove_boot_image
    Strand.create(prog: "RemoveBootImage", label: "start", stack: [{subject_id: id}])
  end

  def path
    version ?
        "/var/storage/images/#{name}-#{version}.raw" :
        "/var/storage/images/#{name}.raw"
  end
end

# Table: boot_image
# Columns:
#  id           | uuid                     | PRIMARY KEY
#  vm_host_id   | uuid                     | NOT NULL
#  name         | text                     | NOT NULL
#  version      | text                     |
#  created_at   | timestamp with time zone | NOT NULL DEFAULT now()
#  activated_at | timestamp with time zone |
#  size_gib     | integer                  | NOT NULL
# Indexes:
#  boot_image_pkey                        | PRIMARY KEY btree (id)
#  boot_image_vm_host_id_name_version_key | UNIQUE btree (vm_host_id, name, version)
# Foreign key constraints:
#  boot_image_vm_host_id_fkey | (vm_host_id) REFERENCES vm_host(id)
# Referenced By:
#  vm_storage_volume | vm_storage_volume_boot_image_id_fkey | (boot_image_id) REFERENCES boot_image(id)
