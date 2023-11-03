# frozen_string_literal: true

require_relative "../../model"

class PostgresTimeline < Sequel::Model
  one_to_one :strand, key: :id
  one_to_one :parent, key: :parent_id, class: self

  include ResourceMethods
  include SemaphoreMethods

  semaphore :destroy

  plugin :column_encryption do |enc|
    enc.column :secret_key
  end

  def bucket_name
    ubid
  end

  def blob_storage
    @blob_storage ||= Project[Config.postgres_service_project_id].minio_clusters.first
  end

  def blob_storage_client
    @blob_storage_client ||= MinioClient.new(
      endpoint: blob_storage.connection_strings.first,
      access_key: Config.postgres_service_blob_storage_access_key,
      secret_key: Config.postgres_service_blob_storage_secret_key
    )
  end
end
