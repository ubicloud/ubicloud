# frozen_string_literal: true

class PostgresTimeline < Sequel::Model
  module Metal
    private

    def metal_walg_config_region
      "us-east-1"
    end

    def metal_blob_storage
      @blob_storage ||= DB.ignore_duplicate_queries do
        MinioCluster[project_id: Config.postgres_service_project_id, location_id: location.id] || MinioCluster[project_id: Config.minio_service_project_id, location_id: location.id]
      end
    end

    def metal_blob_storage_client
      @blob_storage_client ||= Minio::Client.new(
        endpoint: blob_storage_endpoint,
        access_key:,
        secret_key:,
        ssl_ca_data: blob_storage.root_certs
      )
    end

    def metal_list_objects(prefix, delimiter: "")
      blob_storage_client.list_objects(ubid, prefix, delimiter:)
    end

    def metal_create_bucket
      blob_storage_client.create_bucket(ubid)
    end

    def metal_set_lifecycle_policy
      blob_storage_client.set_lifecycle_policy(ubid, ubid, BACKUP_BUCKET_EXPIRATION_DAYS)
    end
  end
end
