# frozen_string_literal: true

require_relative "../../common/lib/util"
require_relative "vm_path"
require_relative "storage_volume"

class StorageCtl
  def start_volumes(volumes, storage_secrets)
    first_exception = nil

    volumes.each { |params|
      device_id = params["device_id"]
      storage_volume = StorageVolume.new(params)
      begin
        storage_volume.start(storage_secrets[device_id])
      rescue => e
        # Volumes might get deleted concurrently, don't raise errors if we
        # can't start a deleted volume.
        first_exception ||= e if !storage_volume.deleted?
      end
    }

    raise first_exception if first_exception
  end
end
