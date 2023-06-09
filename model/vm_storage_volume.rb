# frozen_string_literal: true

require_relative "../model"

class VmStorageVolume < Sequel::Model
  many_to_one :vm

  def device_id
    "#{vm.inhost_name}_#{disk_index}"
  end

  def device_path
    "/dev/disk/by-id/virtio-#{device_id}"
  end
end
