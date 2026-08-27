# frozen_string_literal: true

class VmStorageVolume < Sequel::Model
  module Gcp
    private

    def gcp_device_path
      # Explicit device names expose non-boot disks as persistent-disk-<index>.
      if boot || provider_volume_id
        "/dev/disk/by-id/google-persistent-disk-#{disk_index}"
      else
        "/dev/disk/by-id/google-local-nvme-ssd-#{disk_index - 1}"
      end
    end
  end
end
