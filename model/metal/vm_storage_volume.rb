# frozen_string_literal: true

class VmStorageVolume < Sequel::Model
  module Metal
    private

    def metal_device_path
      "/dev/disk/by-id/virtio-#{device_id}"
    end
  end
end
