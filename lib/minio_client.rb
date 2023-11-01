# frozen_string_literal: true

require "aws-sdk-s3"

class MinioClient
  def initialize(endpoint:, access_key:, secret_key:)
    @client = Aws::S3::Client.new(
      endpoint: endpoint,
      access_key_id: access_key,
      secret_access_key: secret_key,
      force_path_style: true, # Required for MinIO compatibility, though it seems things are working without this as well.
      region: "us-east-1" # This region is not used. It is just passed to make AWS SDK happy.
    )
  end

  def create_bucket(bucket_name:)
    @client.create_bucket(bucket: bucket_name)
  rescue Aws::S3::Errors::BucketAlreadyExists
  end

  def list_objects(bucket_name:, folder_path:)
    objects = []
    is_truncated = true
    continuation_token = nil
    while is_truncated
      response = @client.list_objects_v2(bucket: bucket_name, prefix: folder_path, continuation_token: continuation_token)
      is_truncated = response.is_truncated
      continuation_token = response.next_continuation_token

      objects.concat(response.contents)
    end

    objects
  end
end
