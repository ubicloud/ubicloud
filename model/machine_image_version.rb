# frozen_string_literal: true

require_relative "../model"

class MachineImageVersion < Sequel::Model
  one_to_one :strand, key: :id

  many_to_one :machine_image
  many_to_one :vm
  many_to_one :key_encryption_key_1, class: :StorageKeyEncryptionKey
  one_to_many :vm_storage_volumes, read_only: true
  one_to_many :active_billing_records, class: :BillingRecord, key: :resource_id, read_only: true, &:active

  plugin ResourceMethods
  plugin SemaphoreMethods, :destroy

  def before_destroy
    VmStorageVolume.where(machine_image_version_id: id).update(machine_image_version_id: nil)
    active_billing_records.each(&:finalize)

    kek = key_encryption_key_1
    if kek
      update(key_encryption_key_1_id: nil)
      kek.destroy
    end

    super
  end

  dataset_module Pagination

  def display_location
    machine_image.display_location
  end

  def path
    machine_image.path
  end

  def available?
    state == "available"
  end

  def creating?
    state == "creating"
  end

  def destroying?
    state == "destroying"
  end

  def active?
    !activated_at.nil? && machine_image.active_version&.id == id
  end

  def activate!
    update(activated_at: Time.now)
  end

  def archive_params
    {
      "type" => "archive",
      "archive_bucket" => s3_bucket,
      "archive_prefix" => s3_prefix,
      "archive_endpoint" => s3_endpoint,
      "compression" => "zstd",
      "encrypted" => true,
      "has_session_token" => true
    }
  end
end
