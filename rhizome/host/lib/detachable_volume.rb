# frozen_string_literal: true

require_relative "storage_volume"

# A ubiblk volume that isn't tied to a VM. It is laid out and run like a VM
# disk, but lives in a directory of its own, has a backend service named after
# it, and is owned by the user of whichever VM it is attached to, which can
# change between starts.
class DetachableVolume < StorageVolume
  attr_reader :id

  # owner is the unix user of the VM the volume is attached to, and params
  # are the volume's StorageVolume parameters. Neither is needed to delete
  # the volume.
  def initialize(id, owner = nil, params = {})
    @id = id
    super(owner, {"encrypted" => true}.merge(params))
  end

  def sp
    @sp ||= StoragePath.detachable(@id)
  end

  # Lays the volume out afresh if asked to, over whatever an interrupted
  # layout left, and starts it.
  def ensure_started(key_wrapping_secrets, lay_out:)
    fail "detachable volumes need a vhost block backend with config v2" unless use_config_v2?

    if lay_out
      rm_if_exists(storage_dir)
      prep(key_wrapping_secrets)
    end
    start(key_wrapping_secrets)
  end

  # The volume may be started for a different VM than it was last used by, so
  # hand it and its service to that VM's user first.
  def vhost_backend_start(key_wrapping_secrets)
    stop_service_if_loaded(vhost_user_block_service)
    FileUtils.chown_R(@vm_name, @vm_name, storage_dir)
    vhost_backend_create_service_file
    r "systemctl", "daemon-reload"
    super
  end

  # A volume restarted on the same host is started without its remote source,
  # which it may still be fetching from.
  def needs_network?
    true
  end

  def service_description
    "Vhost Block Backend Service for detachable volume #{@id}"
  end

  def delete
    purge_vhost_backend
    rm_if_exists(storage_dir)
  end
end
