# frozen_string_literal: true

require_relative "../model"

class MachineImage < Sequel::Model
  many_to_one :project
  many_to_one :location
  one_to_many :versions, class: :MachineImageVersion, order: Sequel.desc(:created_at)

  plugin ResourceMethods
  include ObjectTag::Cleanup

  dataset_module Pagination

  dataset_module do
    def for_project(project_id)
      where(Sequel[project_id:] | {visible: true})
    end
  end

  def display_location
    location.display_name
  end

  def path
    "/location/#{display_location}/machine-image/#{ubid}"
  end

  def active_version
    MachineImageVersion.where(machine_image_id: id)
      .exclude(activated_at: nil)
      .order(Sequel.desc(:activated_at))
      .first
  end

  def before_destroy
    versions.each(&:destroy)
    super
  end
end

# Table: machine_image
# Columns:
#  id                      | uuid                     | PRIMARY KEY DEFAULT gen_random_uuid()
#  name                    | text                     | NOT NULL
#  description             | text                     | NOT NULL DEFAULT ''::text
#  project_id              | uuid                     | NOT NULL
#  location_id             | uuid                     | NOT NULL
#  state                   | text                     | NOT NULL
#  s3_bucket               | text                     | NOT NULL
#  s3_prefix               | text                     | NOT NULL
#  s3_endpoint             | text                     | NOT NULL
#  encrypted               | boolean                  | NOT NULL DEFAULT true
#  key_encryption_key_1_id | uuid                     |
#  compression             | text                     | NOT NULL DEFAULT 'zstd'::text
#  size_gib                | integer                  | NOT NULL
#  vm_id                   | uuid                     |
#  version                 | text                     | NOT NULL DEFAULT 'v1'::text
#  active                  | boolean                  | NOT NULL DEFAULT true
#  arch                    | text                     | NOT NULL DEFAULT 'x64'::text
#  visible                 | boolean                  | NOT NULL DEFAULT false
#  created_at              | timestamp with time zone | NOT NULL DEFAULT now()
#  decommissioned_at       | timestamp with time zone |
# Indexes:
#  machine_image_pkey                                    | PRIMARY KEY btree (id)
#  machine_image_project_id_location_id_name_version_key | UNIQUE btree (project_id, location_id, name, version)
# Foreign key constraints:
#  machine_image_key_encryption_key_1_id_fkey | (key_encryption_key_1_id) REFERENCES storage_key_encryption_key(id)
#  machine_image_location_id_fkey             | (location_id) REFERENCES location(id)
#  machine_image_project_id_fkey              | (project_id) REFERENCES project(id)
#  machine_image_vm_id_fkey                   | (vm_id) REFERENCES vm(id) ON DELETE SET NULL
# Referenced By:
#  vm_storage_volume | vm_storage_volume_machine_image_id_fkey | (machine_image_id) REFERENCES machine_image(id) ON DELETE SET NULL
