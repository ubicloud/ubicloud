# frozen_string_literal: true

DEFAULT_STORAGE_DEVICE = "DEFAULT"

class StoragePath
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

  def archive_kek_pipe
    @archive_kek_pipe ||= File.join(storage_dir, "archive-kek.pipe")
  end

  def s3_key_id_pipe
    @s3_key_id_pipe ||= File.join(storage_dir, "s3-key-id.pipe")
  end

  def s3_secret_key_pipe
    @s3_secret_key_pipe ||= File.join(storage_dir, "s3-secret-key.pipe")
  end

  def s3_session_token_pipe
    @s3_session_token_pipe ||= File.join(storage_dir, "s3-session-token.pipe")
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
end
