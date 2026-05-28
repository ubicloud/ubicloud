# frozen_string_literal: true

require "aws-sdk-iam"

class PostgresServer < Sequel::Model
  module Aws
    private

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
      # RAID for data. Avoid relying on VmStorageVolume row count, which is
      # split per a 1900 GiB cap that doesn't match every AWS family's actual
      # per-disk packaging (e.g. r8id.16xlarge ships 1x3800, r8gd.12xlarge
      # ships 3x950). -n suppresses the lsblk header; -e 7 excludes loopback
      # devices (snap mounts).
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
