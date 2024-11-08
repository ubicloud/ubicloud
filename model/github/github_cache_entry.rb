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

# Table: github_cache_entry
# Columns:
#  id               | uuid                     | PRIMARY KEY
#  repository_id    | uuid                     | NOT NULL
#  key              | text                     | NOT NULL
#  version          | text                     | NOT NULL
#  scope            | text                     | NOT NULL
#  size             | bigint                   |
#  upload_id        | text                     |
#  created_at       | timestamp with time zone | NOT NULL DEFAULT now()
#  created_by       | uuid                     | NOT NULL
#  last_accessed_at | timestamp with time zone |
#  last_accessed_by | uuid                     |
#  committed_at     | timestamp with time zone |
# Indexes:
#  github_cache_entry_pkey                                | PRIMARY KEY btree (id)
#  github_cache_entry_repository_id_scope_key_version_key | UNIQUE btree (repository_id, scope, key, version)
#  github_cache_entry_upload_id_key                       | UNIQUE btree (upload_id)
# Foreign key constraints:
#  github_cache_entry_repository_id_fkey | (repository_id) REFERENCES github_repository(id)
