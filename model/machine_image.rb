# frozen_string_literal: true

require_relative "../model"

class MachineImage < Sequel::Model
  one_to_one :strand, key: :id

  many_to_one :project
  many_to_one :location
  many_to_one :vm
  many_to_one :key_encryption_key_1, class: :StorageKeyEncryptionKey
  one_to_many :vm_storage_volumes, read_only: true
  one_to_many :active_billing_records, class: :BillingRecord, key: :resource_id, read_only: true, &:active

  plugin ResourceMethods
  plugin SemaphoreMethods, :destroy
  include ObjectTag::Cleanup

  def before_destroy
    VmStorageVolume.where(machine_image_id: id).update(machine_image_id: nil)
    active_billing_records.each(&:finalize)

    kek = key_encryption_key_1
    update(key_encryption_key_1_id: nil)
    kek.destroy

    super
  end

  dataset_module Pagination

  dataset_module do
    def for_project(project_id)
      where(Sequel[project_id:] | {visible: true}).exclude(state: "decommissioned")
    end
  end

  def display_location
    location.display_name
  end

  def path
    "/location/#{display_location}/machine-image/#{ubid}"
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

  def destroying?
    state == "destroying"
  end

  def archive_params
    {
      "type" => "archive",
      "archive_bucket" => s3_bucket,
      "archive_prefix" => s3_prefix,
      "archive_endpoint" => s3_endpoint,
      "compression" => "zstd",
      "encrypted" => true
    }
  end
end
