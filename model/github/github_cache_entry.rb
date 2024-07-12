# frozen_string_literal: true

require_relative "../../model"

require "aws-sdk-s3"

class GithubCacheEntry < Sequel::Model
  many_to_one :repository, key: :repository_id, class: :GithubRepository

  include ResourceMethods

  def self.ubid_type
    UBID::TYPE_ETC
  end

  def blob_key
    "cache/#{ubid}"
  end

  def after_destroy
    super
    if committed_at.nil?
      begin
        repository.blob_storage_client.abort_multipart_upload(bucket: repository.bucket_name, key: blob_key, upload_id: upload_id)
      rescue Aws::S3::Errors::NoSuchUpload
      end
    end

    begin
      repository.blob_storage_client.delete_object(bucket: repository.bucket_name, key: blob_key)
    rescue Aws::S3::Errors::NoSuchKey
    end
  end
end
