# frozen_string_literal: true

require_relative "../model"

# YYY: Remove all checks against this after upgrading all legacy systems
LEGACY_SPDK_VERSION = "LEGACY_SPDK_VERSION"

class SpdkInstallation < Sequel::Model
  many_to_one :vm_host

  def self.generate_uuid
    UBID.generate(UBID::TYPE_ETC).to_uuid
  end

  def supports_bdev_ubi?
    # We version stock SPDK releases similar to v23.09, and add a ubi version
    # suffix if we package bdev_ubi along with it, similar to v23.09-ubi-0.1.
    version.match?(/^v[0-9]+\.[0-9]+-ubi-.*/)
  end
end
