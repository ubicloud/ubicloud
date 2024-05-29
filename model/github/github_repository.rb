# frozen_string_literal: true

require "aws-sdk-s3"

require_relative "../../model"

class GithubRepository < Sequel::Model
  one_to_one :strand, key: :id
  many_to_one :installation, key: :installation_id, class: :GithubInstallation
  one_to_many :runners, key: :repository_id, class: :GithubRunner
  one_to_many :cache_entries, key: :repository_id, class: :GithubCacheEntry

  include ResourceMethods
  include SemaphoreMethods

  semaphore :destroy

  plugin :column_encryption do |enc|
    enc.column :secret_key
  end

  def bucket_name
    ubid
  end

  def blob_storage_client
    @blob_storage_client ||= Aws::S3::Client.new(
      endpoint: Config.github_cache_blob_storage_endpoint,
      access_key_id: access_key,
      secret_access_key: secret_key,
      region: Config.github_cache_blob_storage_region
    )
  end

  def url_presigner
    @url_presigner ||= Aws::S3::Presigner.new(client: blob_storage_client)
  end
end
