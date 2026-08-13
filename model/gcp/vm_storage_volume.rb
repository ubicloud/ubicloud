# frozen_string_literal: true

class VmStorageVolume < Sequel::Model
  module Gcp
    private

    # Maps a record's disk_index onto an NVMe device index. Only correct when
    # records map one to one onto physical disks, which holds for a single data
    # volume but not for an -lssd machine type that bundles several. Postgres
    # discovers its devices on the guest instead; see
    # PostgresServer::Gcp#gcp_storage_device_paths.
    def gcp_device_path
      if boot
        "/dev/disk/by-id/google-persistent-disk-#{disk_index}"
      else
        "/dev/disk/by-id/google-local-nvme-ssd-#{disk_index - 1}"
      end
    end
  end
end
