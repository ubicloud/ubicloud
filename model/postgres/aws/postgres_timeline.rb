# frozen_string_literal: true

class PostgresTimeline < Sequel::Model
  module Aws
    # How many times a bucket that still reports BucketNotEmpty is re-emptied
    # and re-deleted before the destroy gives up: a couple of passes clears the
    # brief listing/delete race, and more would only spin.
    AWS_BUCKET_DELETE_ATTEMPTS = 3

    def aws_s3_policy_name
      ubid
    end

    def aws_iam_account_id
      location.location_credential_aws.aws_iam_account_id
    end

    def aws_s3_policy_arn
      "arn:aws:iam::#{aws_iam_account_id}:policy/#{aws_s3_policy_name}"
    end

    private

    def aws_generate_walg_config(version)
      walg_credentials = if access_key
        <<-WALG_CONF
AWS_ACCESS_KEY_ID=#{access_key}
AWS_SECRET_ACCESS_KEY=#{secret_key}
        WALG_CONF
      end
      config = <<-WALG_CONF
WALG_S3_PREFIX=s3://#{ubid}
AWS_ENDPOINT=#{blob_storage_endpoint}
#{walg_credentials}
AWS_REGION=#{location.name}
AWS_S3_FORCE_PATH_STYLE=true
PGHOST=/var/run/postgresql
PGDATA=/dat/#{version}/data
      WALG_CONF
      # Append the hardware-sized wal-g knobs (empty unless the feature is enabled).
      config + walg_config_env_contents
    end

    def aws_walg_config_params
      return nil unless (vm = leader.vm)
      family = leader.resource.target_vm_size.split(".").first

      # dense NVMe = storage-optimized "i" families, allows more concurrency.
      {vcpu_count: vm.vcpus, memory_mib: vm.memory_gib * 1024,
       dense_nvme: %w[i8g i8ge i7i i7ie].include?(family)}
    end

    def aws_walg_config_region
      location.name
    end

    def aws_blob_storage
      @blob_storage ||= S3BlobStorage.new("https://s3.#{location.name}.amazonaws.com")
    end

    def aws_blob_storage_client
      @blob_storage_client ||= ::Aws::S3::Client.new(
        region: location.name,
        credentials: location.location_credential_aws.credentials,
        endpoint: blob_storage_endpoint,
        force_path_style: true,
      )
    end

    def aws_list_objects(prefix, delimiter: "")
      response = blob_storage_client.list_objects_v2(bucket: ubid, prefix:, delimiter:)
      objects = response.contents
      while response.is_truncated
        response = blob_storage_client.list_objects_v2(bucket: ubid, prefix:, delimiter:, continuation_token: response.next_continuation_token)
        objects.concat(response.contents)
      end
      objects
    end

    def aws_create_bucket
      create_bucket_configuration = {tags: Util.aws_tags(ubid)}
      create_bucket_configuration[:location_constraint] = location.name unless location.name == "us-east-1"
      blob_storage_client.create_bucket(bucket: ubid, create_bucket_configuration:)
    rescue ::Aws::S3::Errors::BucketAlreadyOwnedByYou
    end

    def aws_set_lifecycle_policy(expiration_days: BACKUP_BUCKET_EXPIRATION_DAYS)
      blob_storage_client.put_bucket_lifecycle_configuration({
        bucket: ubid,
        lifecycle_configuration: {
          rules: [
            {
              id: "DeleteOldBackups",
              status: "Enabled",
              expiration: {
                days: expiration_days,
              },
              filter: {},
            },
          ],
        },
      })
    end

    # Tear down the bucket, then the IAM user, then the policy. The IAM half is
    # existence-driven, not mode-driven: it removes whatever is actually there
    # rather than what the live aws_postgres_iam_access says should be, so a
    # mode flip between create and destroy cannot orphan the half the new mode
    # no longer expects.
    def aws_destroy_blob_storage
      s3_client = blob_storage_client
      attempts = 0
      begin
        loop do
          objects = s3_client.list_objects_v2(bucket: ubid).contents
          break if objects.empty?
          s3_client.delete_objects(bucket: ubid, delete: {objects: objects.map { {key: it.key} }})
        end
        s3_client.delete_bucket(bucket: ubid)
      rescue ::Aws::S3::Errors::NoSuchBucket
        nil
      rescue ::Aws::S3::Errors::BucketNotEmpty
        # A race between the final listing and the delete, not a standing
        # condition: re-empty and retry a bounded number of times.
        retry if (attempts += 1) < AWS_BUCKET_DELETE_ATTEMPTS
        raise
      end

      iam_client = location.location_credential_aws.iam_client

      (ignore_missing_entity { iam_client.list_access_keys(user_name: ubid).access_key_metadata } || []).each do |key|
        ignore_missing_entity { iam_client.delete_access_key(user_name: ubid, access_key_id: key.access_key_id) }
      end
      (ignore_missing_entity { iam_client.list_attached_user_policies(user_name: ubid).attached_policies } || []).each do |policy|
        ignore_missing_entity { iam_client.detach_user_policy(user_name: ubid, policy_arn: policy.policy_arn) }
      end
      ignore_missing_entity { iam_client.delete_user(user_name: ubid) }

      # The policy goes last, whichever mode created it. A policy will not
      # delete while attached, and in iam-access mode it is attached to server
      # roles rather than a user, so detach every holder that remains first.
      if (entities = ignore_missing_entity { iam_client.list_entities_for_policy(policy_arn: aws_s3_policy_arn) })
        entities.policy_users.each { |user| ignore_missing_entity { iam_client.detach_user_policy(user_name: user.user_name, policy_arn: aws_s3_policy_arn) } }
        entities.policy_roles.each { |role| ignore_missing_entity { iam_client.detach_role_policy(role_name: role.role_name, policy_arn: aws_s3_policy_arn) } }
        entities.policy_groups.each { |group| ignore_missing_entity { iam_client.detach_group_policy(group_name: group.group_name, policy_arn: aws_s3_policy_arn) } }
      end
      ignore_missing_entity { iam_client.delete_policy(policy_arn: aws_s3_policy_arn) }
    end

    # Tolerate an IAM entity already being gone. Wrapping each call separately,
    # not the whole teardown, is what keeps one already-deleted entity from
    # abandoning the deletions that would have followed it.
    def ignore_missing_entity
      yield
    rescue ::Aws::IAM::Errors::NoSuchEntity
      nil
    end

    def aws_setup_blob_storage
      iam_client = location.location_credential_aws.iam_client
      policy = iam_client.create_policy(policy_name: aws_s3_policy_name, policy_document: blob_storage_policy.to_json, tags: Util.aws_tags(aws_s3_policy_name))
      unless Config.aws_postgres_iam_access
        iam_client.create_user(user_name: ubid, tags: Util.aws_tags(ubid))
        iam_client.attach_user_policy(user_name: ubid, policy_arn: policy.policy.arn)
        response = iam_client.create_access_key(user_name: ubid)
        update(access_key: response.access_key.access_key_id, secret_key: response.access_key.secret_access_key)
        leader.incr_refresh_walg_credentials
      end
    end

    def aws_generate_blob_storage_credentials?
      !Config.aws_postgres_iam_access
    end
  end
end
