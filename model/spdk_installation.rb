# frozen_string_literal: true

require_relative "../model"

class SpdkInstallation < Sequel::Model
  many_to_one :vm_host
  one_to_many :vm_storage_volumes

  def self.generate_uuid
    UBID.generate(UBID::TYPE_ETC).to_uuid
  end

  def supports_bdev_ubi?
    # We version stock SPDK releases similar to v23.09, and add a ubi version
    # suffix if we package bdev_ubi along with it, similar to v23.09-ubi-0.1.
    version.match?(/^v[0-9]+\.[0-9]+-ubi-.*/)
  end
end
