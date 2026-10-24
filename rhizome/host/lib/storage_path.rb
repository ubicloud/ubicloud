# frozen_string_literal: true

DEFAULT_STORAGE_DEVICE = "DEFAULT"

class StoragePath
  def self.detachable(volume_id)
    raise ArgumentError, "invalid detachable volume id: #{volume_id.inspect}" unless /\Adv[0-9a-z]{24}\z/.match?(volume_id)
    DetachableStoragePath.new(volume_id)
  end

  def initialize(vm_name, device, disk_index)
    @vm_name = vm_name
    @device = device
    @disk_index = disk_index
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

  def kek_pipe
    @kek_pipe ||= File.join(storage_dir, "kek.pipe")
  end

  def vhost_backend_config
    @vhost_backend_config ||= File.join(storage_dir, "vhost-backend.conf")
  end

  def vhost_backend_stripe_source_config
    @vhost_backend_stripe_source_config ||= File.join(storage_dir, "vhost-backend-stripe-source.conf")
  end

  def vhost_backend_secrets_config
    @vhost_backend_secrets_config ||= File.join(storage_dir, "vhost-backend-secrets.conf")
  end

  def vhost_backend_metadata
    @vhost_backend_metadata ||= File.join(storage_dir, "metadata")
  end

  def rpc_socket_path
    @rpc_socket_path ||= File.join(storage_dir, "rpc.sock")
  end

  def vhost_backend_service
    "#{@vm_name}-#{@disk_index}-storage.service"
  end
end

class DetachableStoragePath < StoragePath
  def initialize(volume_id)
    super(nil, DEFAULT_STORAGE_DEVICE, nil)
    @volume_id = volume_id
  end

  def storage_root
    @storage_root ||= File.join(device_path, "detachable", @volume_id)
  end

  def storage_dir
    storage_root
  end

  def vhost_backend_service
    "#{@volume_id}-storage.service"
  end
end
