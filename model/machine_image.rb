# frozen_string_literal: true

require_relative "../model"

class MachineImage < Sequel::Model
  one_to_one :strand, key: :id

  many_to_one :project
  many_to_one :location
  many_to_one :vm
  many_to_one :key_encryption_key_1, class: :StorageKeyEncryptionKey
  one_to_many :active_billing_records, class: :BillingRecord, key: :resource_id, read_only: true, &:active

  plugin ResourceMethods
  plugin SemaphoreMethods, :destroy
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
    "/location/#{display_location}/machine-image/#{name}"
  end

  def available?
    state == "available"
  end

  def creating?
    state == "creating"
  end

  def decommissioned?
    state == "decommissioned"
  end

  def verifying?
    state == "verifying"
  end

  def destroying?
    state == "destroying"
  end

  def encrypted?
    encrypted
  end

  # Archive params needed by ubiblk to fetch stripes from S3.
  def archive_params
    {
      "type" => "archive",
      "archive_bucket" => s3_bucket,
      "archive_prefix" => s3_prefix,
      "archive_endpoint" => s3_endpoint,
      "compression" => compression,
      "encrypted" => encrypted?
    }
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
#  created_at              | timestamp with time zone | NOT NULL DEFAULT now()
#  visible                 | boolean                  | NOT NULL DEFAULT false
# Indexes:
#  machine_image_pkey                            | PRIMARY KEY btree (id)
#  machine_image_project_id_location_id_name_key | UNIQUE btree (project_id, location_id, name)
# Foreign key constraints:
#  machine_image_key_encryption_key_1_id_fkey | (key_encryption_key_1_id) REFERENCES storage_key_encryption_key(id)
#  machine_image_location_id_fkey             | (location_id) REFERENCES location(id)
#  machine_image_project_id_fkey              | (project_id) REFERENCES project(id)
#  machine_image_vm_id_fkey                   | (vm_id) REFERENCES vm(id)
# Referenced By:
#  vm_storage_volume | vm_storage_volume_machine_image_id_fkey | (machine_image_id) REFERENCES machine_image(id)
