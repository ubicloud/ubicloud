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
      blob_storage_client.create_bucket(bucket: ubid, create_bucket_configuration: location_constraint)
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
  end
end
