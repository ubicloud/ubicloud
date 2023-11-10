# frozen_string_literal: true

require_relative "../model"

# YYY: Remove all checks against this after upgrading all legacy systems
LEGACY_SPDK_VERSION = "LEGACY_SPDK_VERSION"

class SpdkInstallation < Sequel::Model
  many_to_one :vm_host

  def self.generate_uuid
    UBID.generate(UBID::TYPE_ETC).to_uuid
  end
end
