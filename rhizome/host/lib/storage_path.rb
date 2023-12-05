# frozen_string_literal: true

DEFAULT_STORAGE_SPACE = "DEFAULT"

class StoragePath
  def initialize(vm_name, storage_space, disk_index)
    @vm_name = vm_name
    @storage_space = storage_space
    @disk_index = disk_index
  end

  def storage_root
    @storage_root ||=
      (@storage_space == DEFAULT_STORAGE_SPACE) ?
        File.join("", "var", "storage", @vm_name) :
        File.join("", "var", "storage", "spaces", @storage_space, @vm_name)
  end

  def storage_dir
    @storage_dir ||= File.join(storage_root, @disk_index.to_s)
  end

  def disk_file
    @disk_file ||= File.join(storage_dir, "disk.raw")
  end

  def data_encryption_key
    @dek_path ||= File.join(storage_dir, "data_encryption_key.json")
  end

  def vhost_sock
    @vhost_sock ||= File.join(storage_dir, "vhost.sock")
  end
end
