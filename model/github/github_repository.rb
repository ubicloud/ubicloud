# frozen_string_literal: true

require "aws-sdk-s3"

require_relative "../../model"

class GithubRepository < Sequel::Model
  one_to_one :strand, key: :id
  many_to_one :installation, key: :installation_id, class: :GithubInstallation
  one_to_many :runners, key: :repository_id, class: :GithubRunner
  one_to_many :cache_entries, key: :repository_id, class: :GithubCacheEntry

  plugin :association_dependencies, cache_entries: :destroy

  include ResourceMethods
  include SemaphoreMethods

  semaphore :destroy

  plugin :column_encryption do |enc|
    enc.column :secret_key
    enc.column :session_token
  end

  CACHE_SIZE_LIMIT = 10 * 1024 * 1024 * 1024 # 10GB
  BLOB_STORAGE_TOKEN_TTL = 5 * 24 * 60 * 60 # 5 days

  def bucket_name
    ubid
  end

  def blob_storage_client
    @blob_storage_client ||= s3_client(access_key, secret_key, session_token)
  end

  def url_presigner
    @url_presigner ||= Aws::S3::Presigner.new(client: blob_storage_client)
  end

  def admin_client
    @admin_client ||= s3_client(Config.github_cache_blob_storage_access_key, Config.github_cache_blob_storage_secret_key)
  end

  def after_destroy
    super
    destroy_blob_storage if access_key
  end

  def refresh_blob_storage_token
    client = CloudflareClient.new(Config.github_cache_blob_storage_api_key)
    access_key, secret_key, session_token = client.create_temporary_token(bucket_name, "object-read-write", BLOB_STORAGE_TOKEN_TTL)
    update(access_key: access_key, secret_key: secret_key, session_token: session_token, last_token_refreshed_at: Time.now)
  end

  def destroy_blob_storage
    begin
      admin_client.delete_bucket(bucket: bucket_name)
    rescue Aws::S3::Errors::NoSuchBucket
    end
    this.update(access_key: nil, secret_key: nil, session_token: nil, last_token_refreshed_at: nil)
  end

  def setup_blob_storage
    DB.transaction do
      lock!
      return if access_key && secret_key && session_token

      begin
        admin_client.create_bucket({
          bucket: bucket_name,
          create_bucket_configuration: {location_constraint: Config.github_cache_blob_storage_region}
        })
      rescue Aws::S3::Errors::BucketAlreadyOwnedByYou
      end

      refresh_blob_storage_token
    end
  end

  private def s3_client(access_key_id, secret_access_key, session_token = nil)
    Aws::S3::Client.new(
      endpoint: Config.github_cache_blob_storage_endpoint,
      access_key_id:,
      secret_access_key:,
      session_token:,
      region: Config.github_cache_blob_storage_region,
      request_checksum_calculation: "when_required",
      response_checksum_validation: "when_required"
    )
  end
end

# Table: github_repository
# Columns:
#  id                      | uuid                     | PRIMARY KEY
#  installation_id         | uuid                     |
#  name                    | text                     | NOT NULL
#  created_at              | timestamp with time zone | NOT NULL DEFAULT CURRENT_TIMESTAMP
#  last_job_at             | timestamp with time zone | NOT NULL DEFAULT CURRENT_TIMESTAMP
#  last_check_at           | timestamp with time zone | NOT NULL DEFAULT CURRENT_TIMESTAMP
#  default_branch          | text                     |
#  access_key              | text                     |
#  secret_key              | text                     |
#  session_token           | text                     |
#  last_token_refreshed_at | timestamp with time zone |
# Indexes:
#  github_repository_pkey                       | PRIMARY KEY btree (id)
#  github_repository_installation_id_name_index | UNIQUE btree (installation_id, name)
# Foreign key constraints:
#  github_repository_installation_id_fkey | (installation_id) REFERENCES github_installation(id)
# Referenced By:
#  github_cache_entry | github_cache_entry_repository_id_fkey | (repository_id) REFERENCES github_repository(id)
#  github_runner      | github_runner_repository_id_fkey      | (repository_id) REFERENCES github_repository(id)
