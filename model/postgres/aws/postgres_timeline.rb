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

    def aws_generate_walg_config(version, server)
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
      config + walg_config_env_contents(server)
    end

    def aws_walg_config_params(server)
      return nil unless (vm = server.vm)
      family = server.resource.target_vm_size.split(".").first

      # dense NVMe = storage-optimized "i" families, allows more concurrency.
      {vcpu_count: vm.vcpus, memory_mib: vm.memory_gib * 1024,
       dense_nvme: %w[i8g i8ge i7i i7ie].freeze.include?(family)}
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

      sweep_iam_leftovers(iam_client) if Config.aws_postgres_blob_storage_iam_sweep
      delete_s3_policy(iam_client)
    end

    # delete_policy refuses a policy that holds more than its default version, and
    # aws_refresh_blob_storage_policy leaves a version behind for every policy-document
    # change the timeline has lived through. Clear the extra versions only after the
    # conflict reports them, so a timeline that never got a second version stays
    # destroyable without version-level IAM permissions.
    def delete_s3_policy(iam_client)
      attempts = 0
      begin
        ignore_missing_entity { iam_client.delete_policy(policy_arn: aws_s3_policy_arn) }
      rescue ::Aws::IAM::Errors::DeleteConflict
        raise if (attempts += 1) > 1
        delete_nondefault_policy_versions(iam_client)
        retry
      end
    end

    # Delete every version but the default one, which goes with the policy itself. A
    # managed policy holds at most 5 versions, so one listing covers all of them.
    def delete_nondefault_policy_versions(iam_client)
      versions = ignore_missing_entity { iam_client.list_policy_versions(policy_arn: aws_s3_policy_arn).versions } || []
      versions.reject(&:is_default_version).each do |version|
        ignore_missing_entity { iam_client.delete_policy_version(policy_arn: aws_s3_policy_arn, version_id: version.version_id) }
      end
    end

    # A deployment that stays in iam-access mode has none of this. Setup creates
    # no user and no access key, and the policy it attaches to each server role
    # is detached by VM destroy before the role goes away.
    #
    # That detach in prog/vm/aws/nexus is gated on aws_postgres_iam_access as
    # well, so flipping to access-key mode leaves roles still holding the policy
    # and delete_role failing on them. The reverse flip leaves the user and key
    # of every timeline created before it. Either way the leftovers outlive the
    # mode that made them and only get cleared here, so the sweep defaults on
    # and only a deployment that has never left iam-access mode should skip it.
    def sweep_iam_leftovers(iam_client)
      (ignore_missing_entity { iam_client.list_access_keys(user_name: ubid).access_key_metadata } || []).each do |key|
        ignore_missing_entity { iam_client.delete_access_key(user_name: ubid, access_key_id: key.access_key_id) }
      end
      (ignore_missing_entity { iam_client.list_attached_user_policies(user_name: ubid).attached_policies } || []).each do |policy|
        ignore_missing_entity { iam_client.detach_user_policy(user_name: ubid, policy_arn: policy.policy_arn) }
      end
      ignore_missing_entity { iam_client.delete_user(user_name: ubid) }

      # A policy will not delete while attached, and in iam-access mode it is
      # attached to server roles rather than a user, so detach every holder
      # that remains before the caller deletes it.
      if (entities = ignore_missing_entity { iam_client.list_entities_for_policy(policy_arn: aws_s3_policy_arn) })
        entities.policy_users.each { |user| ignore_missing_entity { iam_client.detach_user_policy(user_name: user.user_name, policy_arn: aws_s3_policy_arn) } }
        entities.policy_roles.each { |role| ignore_missing_entity { iam_client.detach_role_policy(role_name: role.role_name, policy_arn: aws_s3_policy_arn) } }
        entities.policy_groups.each { |group| ignore_missing_entity { iam_client.detach_group_policy(group_name: group.group_name, policy_arn: aws_s3_policy_arn) } }
      end
    end

    # Tolerate an IAM entity already being gone. Wrapping each call separately,
    # not the whole teardown, is what keeps one already-deleted entity from
    # abandoning the deletions that would have followed it.
    def ignore_missing_entity
      yield
    rescue ::Aws::IAM::Errors::NoSuchEntity
      nil
    end

    def ignore_entity_already_exists
      yield
    rescue ::Aws::IAM::Errors::EntityAlreadyExists
      nil
    end

    def aws_setup_blob_storage
      iam_client = location.location_credential_aws.iam_client
      generate_credentials = aws_generate_blob_storage_credentials?
      policy_document = writer_user_policy_document(generate_credentials)
      policy_arn = ignore_entity_already_exists { iam_client.create_policy(policy_name: aws_s3_policy_name, policy_document: policy_document.to_json, tags: Util.aws_tags(aws_s3_policy_name)).policy.arn }
      policy_arn ||= aws_s3_policy_arn

      if generate_credentials
        ignore_entity_already_exists { iam_client.create_user(user_name: ubid, tags: Util.aws_tags(ubid)) }
        iam_client.attach_user_policy(user_name: ubid, policy_arn:)
        iam_client.list_access_keys(user_name: ubid).access_key_metadata.each do |key|
          ignore_missing_entity { iam_client.delete_access_key(user_name: ubid, access_key_id: key.access_key_id) }
        end
        response = iam_client.create_access_key(user_name: ubid)
        update(access_key: response.access_key.access_key_id, secret_key: response.access_key.secret_access_key)

        # it's possible that the leader has already been destroyed
        leader&.incr_refresh_walg_credentials
      end
    end

    def aws_generate_blob_storage_credentials?
      !Config.aws_postgres_iam_access
    end

    # The bucket-access policy for the timeline's writer user. When the timeline owns a
    # static writer credential, it also grants sts:GetFederationToken so we can federate
    # a read-only download session down from it (see #aws_create_download_credentials).
    # In instance-profile mode the same policy is attached to the Postgres VM role, which
    # must not get GetFederationToken; and since a federated session is only ever the
    # intersection with the inline session policy, granting it here cannot escalate
    # beyond the writer user's bucket-scoped S3 access.
    def writer_user_policy_document(generate_credentials)
      policy_document = blob_storage_policy
      if generate_credentials
        policy_document[:Statement] << {Effect: "Allow", Action: ["sts:GetFederationToken"], Resource: ["arn:aws:sts::#{aws_iam_account_id}:federated-user/#{ubid}"]}
      end
      policy_document
    end

    # Re-point the writer user's managed policy at the current policy document, so
    # timelines created before a policy change (such as the sts:GetFederationToken grant
    # that backup downloads need) pick it up without recreating their IAM user. No-op for
    # instance-profile timelines, which have no writer user or user-attached policy.
    def aws_refresh_blob_storage_policy
      return unless aws_generate_blob_storage_credentials?

      iam_client = location.location_credential_aws.iam_client
      policy_document = writer_user_policy_document(true)

      # A managed policy keeps at most 5 versions; drop the oldest non-default one before
      # adding the new default when we are already at the limit. list_policy_versions is
      # eventually consistent, so a stale undercount can still let the create trip the
      # cap: prune against a fresh listing and retry once if it does.
      attempts = 0
      versions = iam_client.list_policy_versions(policy_arn: aws_s3_policy_arn).versions
      begin
        prune_oldest_policy_version(iam_client, versions) if versions.count >= 5
        iam_client.create_policy_version(policy_arn: aws_s3_policy_arn, policy_document: policy_document.to_json, set_as_default: true)
      rescue ::Aws::IAM::Errors::LimitExceeded
        raise unless (attempts += 1) < 2
        versions = iam_client.list_policy_versions(policy_arn: aws_s3_policy_arn).versions
        retry
      end
    end

    # Delete the oldest non-default version of the writer policy to free a slot under
    # IAM's 5-version cap. Tolerate the version already being gone, since the listing
    # that selected it is eventually consistent.
    def prune_oldest_policy_version(iam_client, versions)
      oldest = versions.reject(&:is_default_version).min_by(&:create_date)
      ignore_missing_entity { iam_client.delete_policy_version(policy_arn: aws_s3_policy_arn, version_id: oldest.version_id) }
    end

    # Federate a short-lived, read-only session down from this timeline's own writer
    # IAM user -- not the account-level credential, which only manages buckets and has
    # no object-read access (so a session federated from it would be empty). The writer
    # user is already bucket-scoped, and GetFederationToken intersects its policy with
    # the inline read-only policy, so the resulting session can only read this bucket.
    def aws_create_download_credentials(duration_seconds: DOWNLOAD_CREDENTIALS_DURATION_SECONDS)
      unless access_key
        fail "Backup download credentials require per-timeline blob storage credentials, which are not configured for this resource"
      end

      sts_client = ::Aws::STS::Client.new(region: location.name, credentials: ::Aws::Credentials.new(access_key, secret_key))
      response = sts_client.get_federation_token(
        name: ubid,
        policy: download_blob_storage_policy.to_json,
        duration_seconds:,
      )

      credentials = response.credentials
      {
        access_key_id: credentials.access_key_id,
        secret_access_key: credentials.secret_access_key,
        session_token: credentials.session_token,
        expiration: credentials.expiration,
      }
    end
  end
end
