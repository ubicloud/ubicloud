# frozen_string_literal: true

class PostgresTimeline < Sequel::Model
  module Aws
    def aws_s3_policy_name
      ubid
    end

    def aws_iam_account_id
      location.location_credential.aws_iam_account_id
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
      <<-WALG_CONF
WALG_S3_PREFIX=s3://#{ubid}
AWS_ENDPOINT=#{blob_storage_endpoint}
#{walg_credentials}
AWS_REGION=#{location.name}
AWS_S3_FORCE_PATH_STYLE=true
PGHOST=/var/run/postgresql
PGDATA=/dat/#{version}/data
      WALG_CONF
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
        credentials: location.location_credential.credentials,
        endpoint: blob_storage_endpoint,
        force_path_style: true
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
      location_constraint = (location.name == "us-east-1") ? nil : {location_constraint: location.name}
      begin
        blob_storage_client.create_bucket(bucket: ubid, create_bucket_configuration: location_constraint)
      rescue ::Aws::S3::Errors::BucketAlreadyOwnedByYou
        # Ignore if bucket already exists
      end
    end

    def aws_set_lifecycle_policy
      blob_storage_client.put_bucket_lifecycle_configuration({
        bucket: ubid,
        lifecycle_configuration: {
          rules: [
            {
              id: "DeleteOldBackups",
              status: "Enabled",
              expiration: {
                days: BACKUP_BUCKET_EXPIRATION_DAYS
              },
              filter: {}
            }
          ]
        }
      })
    end

    def aws_destroy_blob_storage
      iam_client = location.location_credential.iam_client
      if Config.aws_postgres_iam_access
        iam_client.delete_policy(policy_arn: aws_s3_policy_arn)
      else
        iam_client.list_attached_user_policies(user_name: ubid).attached_policies.each do
          iam_client.detach_user_policy(user_name: ubid, policy_arn: it.policy_arn)
          iam_client.delete_policy(policy_arn: it.policy_arn)
        end

        iam_client.list_access_keys(user_name: ubid).access_key_metadata.each do
          iam_client.delete_access_key(user_name: ubid, access_key_id: it.access_key_id)
        end
        iam_client.delete_user(user_name: ubid)
      end
    end

    def aws_setup_blob_storage
      iam_client = location.location_credential.iam_client
      policy = iam_client.create_policy(policy_name: aws_s3_policy_name, policy_document: blob_storage_policy.to_json)
      unless Config.aws_postgres_iam_access
        iam_client.create_user(user_name: ubid)
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
