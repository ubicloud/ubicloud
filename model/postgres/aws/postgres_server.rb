# frozen_string_literal: true

class PostgresServer < Sequel::Model
  module Aws
    private

    def aws_add_provider_configs(configs)
      configs[:log_line_prefix] = "'%m [%p:%l] (%x,%v): host=%r,db=%d,user=%u,app=%a,client=%h '"
      configs[:log_connections] = "on"
      configs[:log_disconnections] = "on"
    end

    def aws_refresh_walg_blob_storage_credentials
      # nothing
    end

    def aws_storage_device_paths
      # On AWS, pick the largest block device to use as the data disk,
      # since the device path detected by the VmStorageVolume is not always
      # correct.
      storage_device_count = vm.vm_storage_volumes.count { it.boot == false }
      vm.sshable.cmd("lsblk -b -d -o NAME,SIZE | sort -n -k2 | tail -n:storage_device_count |  awk '{print \"/dev/\"$1}'", storage_device_count:).strip.split
    end

    def aws_attach_s3_policy_if_needed
      if Config.aws_postgres_iam_access && vm.aws_instance.iam_role
        timeline.location.location_credential.iam_client.attach_role_policy(role_name: vm.aws_instance.iam_role, policy_arn: timeline.aws_s3_policy_arn)
      end
    end
  end
end
