# frozen_string_literal: true

class VmStorageVolume < Sequel::Model
  module Gcp
    private

    def gcp_device_path
      # non-boot persistent disks get explicit device_name
      # persistent-disk-<index> at attach, surfaced by google_nvme_id udev
      if boot || provider_volume_id
        "/dev/disk/by-id/google-persistent-disk-#{disk_index}"
      else
        "/dev/disk/by-id/google-local-nvme-ssd-#{disk_index - 1}"
      end
    end
  end
end
