# frozen_string_literal: true

class PostgresTimeline < Sequel::Model
  GcsBlobStorage = Data.define(:url)
  GcsFileWrapper = Data.define(:key, :last_modified)

  module Gcp
    private

    def gcp_generate_walg_config(version)
      <<-WALG_CONF
WALG_GS_PREFIX=gs://#{ubid}
GOOGLE_APPLICATION_CREDENTIALS=/etc/postgresql/gcs-sa-key.json
PGHOST=/var/run/postgresql
PGDATA=/dat/#{version}/data
      WALG_CONF
    end

    def gcp_walg_config_region
      location.name.delete_prefix("gcp-")
    end

    def gcp_blob_storage
      @blob_storage ||= GcsBlobStorage.new("https://storage.googleapis.com")
    end

    def gcp_blob_storage_client
      @blob_storage_client ||= location.location_credential_gcp.storage_client
    end

    def gcp_list_objects(prefix, delimiter: "")
      bucket = blob_storage_client.bucket(ubid)
      return [] unless bucket

      delimiter = nil if delimiter.empty?
      files = bucket.files(prefix:, delimiter:)
      all_files = files.to_a
      while (token = files.token)
        files = bucket.files(prefix:, delimiter:, token:)
        all_files.concat(files.to_a)
      end

      all_files.map! { |f| GcsFileWrapper.new(f.name, f.updated_at.to_time) }
    end

    def gcp_create_bucket
      # Emit before the create call so the e2e cleanup grep picks the
      # bucket up even if the bucket already exists from a prior strand
      # entry (AlreadyExistsError below).
      Clog.emit("GCP GCS bucket created", {gcp_gcs_bucket_created: ubid})
      blob_storage_client.create_bucket(ubid, location: location.name.delete_prefix("gcp-")) do |b|
        b.uniform_bucket_level_access = true
        b.labels = {"ubicloud" => Config.provider_resource_tag_value}
      end
    rescue Google::Cloud::AlreadyExistsError
      nil
    end

    def gcp_set_lifecycle_policy
      bucket = blob_storage_client.bucket(ubid)
      bucket.lifecycle do |l|
        l.add_delete_rule(age: BACKUP_BUCKET_EXPIRATION_DAYS)
      end
    end

    def gcp_destroy_blob_storage
      bucket = blob_storage_client.bucket(ubid)
      if bucket
        bucket.files.each(&:delete)
        bucket.delete
      end

      if access_key
        credential = location.location_credential_gcp
        begin
          credential.iam_client.delete_project_service_account(
            "projects/-/serviceAccounts/#{access_key}",
          )
        rescue Google::Apis::ClientError => e
          raise unless e.status_code == 404
          # SA already deleted. idempotent path
          nil
        end
      end
    end

    def gcp_setup_blob_storage
      # GCS setup is automatic via SA credentials (no-op).
    end

    def gcp_generate_blob_storage_credentials?
      false
    end
  end
end
