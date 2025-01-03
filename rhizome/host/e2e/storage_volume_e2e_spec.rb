# frozen_string_literal: true

require_relative "../lib/storage_volume"
require_relative "../../common/lib/util"
require "fileutils"
require "openssl"
require "base64"

return if ENV["RUN_E2E_TESTS"] != "1"

RSpec.describe StorageVolume do
  let(:vm) { "vm012345" }

  before do
    r "sudo adduser #{vm}"
  end

  after do
    r "sudo userdel --remove #{vm}"

    # YYY: Don't delete manually after moving the storage dir purge logic from
    # vm_setup.rb to storage_volume.rb.
    rm_if_exists("/var/storage/#{vm}")
  end

  describe "#encrypted_storage_volume" do
    let(:key_wrapping_secrets) {
      key_wrapping_algorithm = "aes-256-gcm"
      cipher = OpenSSL::Cipher.new(key_wrapping_algorithm)
      {
        "algorithm" => key_wrapping_algorithm,
        "key" => Base64.encode64(cipher.random_key),
        "init_vector" => Base64.encode64(cipher.random_iv),
        "auth_data" => "Ubicloud-Storage-Auth"
      }
    }
    let(:encrypted_sv) {
      described_class.new(vm, {
        "disk_index" => 0,
        "device_id" => "#{vm}_0",
        "encrypted" => true,
        "size_gib" => 5,
        "image" => nil,
        "spdk_version" => DEFAULT_SPDK_VERSION
      })
    }

    it "ensures encrypted prep, start, and purge are idempotent" do
      encrypted_sv.prep(key_wrapping_secrets)
      expect { encrypted_sv.prep(key_wrapping_secrets) }.not_to raise_error
      encrypted_sv.start(key_wrapping_secrets)
      expect { encrypted_sv.start(key_wrapping_secrets) }.not_to raise_error
      encrypted_sv.purge_spdk_artifacts
      expect { encrypted_sv.purge_spdk_artifacts }.not_to raise_error
    end
  end

  describe "#unencrypted_storage_volume" do
    let(:unencrypted_sv) {
      described_class.new(vm, {
        "disk_index" => 1,
        "device_id" => "#{vm}_1",
        "encrypted" => false,
        "size_gib" => 5,
        "image" => nil,
        "spdk_version" => DEFAULT_SPDK_VERSION
      })
    }

    it "ensures unencrypted prep, start, and purge are idempotent" do
      unencrypted_sv.prep(nil)
      expect { unencrypted_sv.prep(nil) }.not_to raise_error
      unencrypted_sv.start(nil)
      expect { unencrypted_sv.start(nil) }.not_to raise_error
      unencrypted_sv.purge_spdk_artifacts
      expect { unencrypted_sv.purge_spdk_artifacts }.not_to raise_error
    end
  end
end
