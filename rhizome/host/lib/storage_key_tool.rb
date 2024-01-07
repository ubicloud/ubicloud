# frozen_string_literal: true

require_relative "../../common/lib/util"
require_relative "storage_path"
require_relative "../lib/storage_key_encryption"

class StorageKeyTool
  def initialize(vm_name, storage_device, disk_index)
    sp = StoragePath.new(vm_name, storage_device, disk_index)
    @key_file = sp.data_encryption_key
    @new_key_file = "#{@key_file}.new"
  end

  def reencrypt_key_file(old_key, new_key)
    sek_old = StorageKeyEncryption.new(old_key)
    sek_new = StorageKeyEncryption.new(new_key)

    data_encryption_key = sek_old.read_encrypted_dek(@key_file)

    sek_new.write_encrypted_dek(@new_key_file, data_encryption_key)
  end

  def test_keys(old_key, new_key)
    sek_old = StorageKeyEncryption.new(old_key)
    sek_new = StorageKeyEncryption.new(new_key)

    old_dek = sek_old.read_encrypted_dek(@key_file)
    new_dek = sek_new.read_encrypted_dek(@new_key_file)

    if old_dek[:cipher] != new_dek[:cipher]
      raise "ciphers don't match"
    end

    if old_dek[:key] != new_dek[:key]
      raise "keys don't match"
    end

    if old_dek[:key2] != new_dek[:key2]
      raise "second keys don't match"
    end
  end

  def retire_old_key
    File.rename @new_key_file, @key_file
    sync_parent_dir(@key_file)
  end
end
