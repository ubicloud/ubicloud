# frozen_string_literal: true

require "aws-sdk-ec2"
require "aws-sdk-iam"

class PostgresServer < Sequel::Model
  module Aws
    private

    def aws_instance_store_device_glob
      "/dev/disk/by-id/nvme-Amazon_EC2_NVMe_Instance_Storage*"
    end

    # EBS volume size limit auto-grow stops at
    def aws_wal_volume_size_cap_gib
      (resource.wal_drive_type == PostgresResource::WalDriveType::IO2) ? 65536 : 16384
    end

    def aws_grow_wal_volume(size_gib)
      ec2 = vm.location.location_credential_aws.client
      volume_id = wal_volume.provider_volume_id
      # prior execution may've succeeded, accept if disk already resized
      if ec2.describe_volumes(volume_ids: [volume_id]).volumes.first.size < size_gib
        ec2.modify_volume(volume_id:, size: size_gib)
      end
      true
    rescue ::Aws::EC2::Errors::VolumeModificationRateExceeded => ex
      # AWS allows resizing disk every 6 hours
      Clog.emit("wal volume resize deferred", Util.exception_to_hash(ex, into: {postgres_server_id: id}))
      false
    end

    def aws_add_provider_configs(configs)
      configs[:log_connections] = "on"
      configs[:log_disconnections] = "on"
    end

    def aws_refresh_walg_blob_storage_credentials
      # nothing
    end

    def aws_storage_device_paths
      # Sort whole block devices by size and drop the smallest (EBS boot, fixed
      # at 16 GiB). Remaining devices are instance-store NVMes — the disks we
      # RAID for data.
      vm.sshable.cmd("lsblk -b -d -n -e 7 -o NAME,SIZE | sort -n -k2 | tail -n +2 | awk '{print \"/dev/\"$1}'").strip.split
    end

    def aws_attach_s3_policy_if_needed
      if Config.aws_postgres_iam_access && vm.aws_instance.iam_role
        client.attach_role_policy(role_name: vm.aws_instance.iam_role, policy_arn: timeline.aws_s3_policy_arn)
        _aws_detach_parent_s3_policy
      end
    end

    def _aws_detach_parent_s3_policy
      client.detach_role_policy(role_name: vm.aws_instance.iam_role, policy_arn: timeline.parent.aws_s3_policy_arn) if timeline.parent
    rescue ::Aws::IAM::Errors::NoSuchEntity
    end

    def aws_increment_s3_new_timeline
      incr_configure_s3_new_timeline
    end

    def client
      @client ||= timeline.location.location_credential_aws.iam_client
    end
  end
end
