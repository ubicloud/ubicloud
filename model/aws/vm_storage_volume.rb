# frozen_string_literal: true

class VmStorageVolume < Sequel::Model
  module Aws
    private

    def aws_device_path
      if provider_volume_id
        # EBS by-id names omit the volume ID's dash and survive NVMe reordering.
        "/dev/disk/by-id/nvme-Amazon_Elastic_Block_Store_#{provider_volume_id.sub("-", "")}"
      else
        "/dev/nvme#{disk_index}n1"
      end
    end
  end
end
