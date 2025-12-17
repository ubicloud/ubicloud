# frozen_string_literal: true

class VmStorageVolume < Sequel::Model
  module Aws
    private

    def aws_device_path
      "/dev/nvme#{disk_index}n1"
    end
  end
end
