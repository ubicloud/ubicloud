# frozen_string_literal: true

require_relative "../../common/lib/util"
require_relative "storage_path"
require_relative "../lib/storage_key_encryption"

# Rotates the key-encryption-key (KEK) that wraps a storage volume's data
# encryption key (DEK). Only the wrapped DEK is re-wrapped with the new KEK;
# the DEK and on-disk ciphertext are unchanged, so nothing is rewritten and
# rotation takes effect on the next backend start.
#
# The wrapped DEK lives in a different file/format per backend, so the caller
# passes the volume's vhost_block_backend_version and the format is derived
# from it. Only SPDK volumes ("" / nil) are handled here; the ubiblk formats
# are added in a follow-up.
class StorageKeyTool
  def initialize(vm_name, storage_device, disk_index, vhost_block_backend_version)
    @vm_name = vm_name
    @disk_index = disk_index
    @sp = StoragePath.new(vm_name, storage_device, disk_index)
    @format = format_for(vhost_block_backend_version)
    @key_file = key_file
    @new_key_file = "#{@key_file}.new"
  end

  def format_for(version)
    return :spdk if version.nil? || version.empty?
    fail "rotating a #{version} volume is not supported yet"
  end

  def key_file
    case @format
    when :spdk then @sp.data_encryption_key
    end
  end

  def reencrypt_key_file(old_key, new_key)
    write_dek(@new_key_file, new_key, read_dek(@key_file, old_key))
  end

  def test_keys(old_key, new_key)
    old_dek = read_dek(@key_file, old_key)
    new_dek = read_dek(@new_key_file, new_key)

    raise "ciphers don't match" if old_dek[:cipher] != new_dek[:cipher]
    raise "keys don't match" if old_dek[:key] != new_dek[:key]
    raise "second keys don't match" if old_dek[:key2] != new_dek[:key2]
  end

  def retire_old_key
    File.rename @new_key_file, @key_file
    sync_parent_dir(@key_file)
  end

  private

  # Reads and unwraps the DEK from +file+ with +kek+ as {cipher:, key:, key2:}.
  def read_dek(file, kek)
    StorageKeyEncryption.new(kek).read_encrypted_dek(file)
  end

  # Re-wraps +dek+ with +kek+ into +file+.
  def write_dek(file, kek, dek)
    StorageKeyEncryption.new(kek).write_encrypted_dek(file, dek)
  end
end
