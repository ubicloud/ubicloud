# frozen_string_literal: true

class PostgresTimeline < Sequel::Model
  GcsBlobStorage = Struct.new(:url)

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
      @blob_storage_client ||= location.location_credential.storage_client
    end

    def gcp_list_objects(prefix, delimiter: "")
      bucket = blob_storage_client.bucket(ubid)
      return [] unless bucket

      files = bucket.files(prefix:, delimiter: delimiter.empty? ? nil : delimiter)
      all_files = files.to_a
      while (token = files.token)
        files = bucket.files(prefix:, delimiter: delimiter.empty? ? nil : delimiter, token:)
        all_files.concat(files.to_a)
      end

      all_files.map { |f| GcsFileWrapper.new(f.name, f.updated_at.to_time) }
    end

    def gcp_create_bucket
      blob_storage_client.create_bucket(ubid, location: location.name.delete_prefix("gcp-")) do |b|
        b.uniform_bucket_level_access = true
      end
    rescue Google::Cloud::AlreadyExistsError
      # Ignore if bucket already exists
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
        credential = location.location_credential
        begin
          credential.iam_client.delete_project_service_account(
            "projects/-/serviceAccounts/#{access_key}"
          )
        rescue Google::Apis::ClientError
          # SA may already be deleted
        end
      end
    end

    def gcp_setup_blob_storage
      # GCS setup is automatic via SA credentials — no-op
    end

    def gcp_generate_blob_storage_credentials?
      false
    end
  end

  GcsFileWrapper = Struct.new(:key, :last_modified)
end

# Table: postgres_timeline
# Columns:
#  id                        | uuid                     | PRIMARY KEY
#  created_at                | timestamp with time zone | NOT NULL DEFAULT now()
#  parent_id                 | uuid                     |
#  access_key                | text                     |
#  secret_key                | text                     |
#  latest_backup_started_at  | timestamp with time zone |
#  location_id               | uuid                     |
#  cached_earliest_backup_at | timestamp with time zone |
# Indexes:
#  postgres_timeline_pkey | PRIMARY KEY btree (id)
# Foreign key constraints:
#  postgres_timeline_location_id_fkey | (location_id) REFERENCES location(id)
# Referenced By:
#  postgres_server | postgres_server_timeline_id_fkey | (timeline_id) REFERENCES postgres_timeline(id)
