# frozen_string_literal: true

class PostgresTimeline < Sequel::Model
  module Metal
    private

    def metal_generate_walg_config(version)
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
AWS_REGION=us-east-1
AWS_S3_FORCE_PATH_STYLE=true
PGHOST=/var/run/postgresql
PGDATA=/dat/#{version}/data
      WALG_CONF
    end

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

    def metal_destroy_blob_storage
      admin_client = Minio::Client.new(
        endpoint: blob_storage_endpoint,
        access_key: blob_storage.admin_user,
        secret_key: blob_storage.admin_password,
        ssl_ca_data: blob_storage.root_certs
      )
      admin_client.admin_remove_user(access_key)
      admin_client.admin_policy_remove(ubid)
    end

    def metal_setup_blob_storage
      admin_client = Minio::Client.new(
        endpoint: blob_storage_endpoint,
        access_key: blob_storage.admin_user,
        secret_key: blob_storage.admin_password,
        ssl_ca_data: blob_storage.root_certs
      )
      admin_client.admin_add_user(access_key, secret_key)
      admin_client.admin_policy_add(ubid, blob_storage_policy)
      admin_client.admin_policy_set(ubid, access_key)
    end

    def metal_generate_blob_storage_credentials?
      true
    end
  end
end
