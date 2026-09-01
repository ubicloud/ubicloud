# frozen_string_literal: true

class VmStorageVolume < Sequel::Model
  module Aws
    private

    def aws_device_path
      if (provider_id = network_volume&.provider_id)
        # EBS by-id names omit the volume ID's dash and survive NVMe reordering.
        "/dev/disk/by-id/nvme-Amazon_Elastic_Block_Store_#{provider_id.sub("-", "")}"
      else
        "/dev/nvme#{disk_index}n1"
      end
    end
  end
end
