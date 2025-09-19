# frozen_string_literal: true

DEFAULT_STORAGE_DEVICE = "DEFAULT"

class StoragePath
  def initialize(vm_name, device, disk_index, detachable, id)
    @vm_name = vm_name
    @device = device
    @disk_index = disk_index
    @detachable = detachable
    @id = id
  end

  def device_path
    @device_path ||=
      (@device == DEFAULT_STORAGE_DEVICE) ?
          File.join("", "var", "storage") :
          File.join("", "var", "storage", "devices", @device)
  end

  def storage_root
    @storage_root ||= File.join(device_path, @vm_name)
  end

  def storage_dir
    @storage_dir ||=
      @detachable ?
        File.join(device_path, @id.to_s) :
        File.join(storage_root, @disk_index.to_s)
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

  def kek_pipe
    @kek_pipe ||= File.join(storage_dir, "kek.pipe")
  end

  def vhost_backend_config
    @vhost_backend_config ||= File.join(storage_dir, "vhost-backend.conf")
  end

  def vhost_backend_metadata
    @vhost_backend_metadata ||= File.join(storage_dir, "metadata")
  end
end
