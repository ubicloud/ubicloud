# frozen_string_literal: true

class PostgresTimeline < Sequel::Model
  GcsBlobStorage = Data.define(:url)
  GcsFileWrapper = Data.define(:key, :last_modified, :size)

  module Gcp
    private

    def gcp_generate_walg_config(version, server)
      walg_credentials = if access_key
        <<-WALG_CONF
GOOGLE_APPLICATION_CREDENTIALS=/etc/postgresql/gcs-sa-key.json
        WALG_CONF
      end
      config = <<-WALG_CONF
WALG_GS_PREFIX=gs://#{ubid}
#{walg_credentials}
PGHOST=/var/run/postgresql
PGDATA=/dat/#{version}/data
      WALG_CONF
      config + walg_config_env_contents(server)
    end

    def gcp_walg_config_params(server)
      return nil unless (vm = server.vm)

      {vcpu_count: vm.vcpus, memory_mib: vm.memory_gib * 1024}
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

    def gcp_list_objects_page(prefix, delimiter: "", start_after: nil, token: nil)
      api = location.location_credential_gcp.storage_api_client
      delimiter = nil if delimiter.empty?

      # A page token already encodes its position, and the other providers only
      # accept a cursor on the first request.
      response = api.list_objects(ubid, prefix:, delimiter:, start_offset: (start_after if token.nil?),
        page_token: token, max_results: 1000)
      objects = response.items || [].freeze
      # startOffset is inclusive, start_after is not.
      objects = objects.drop(1) if token.nil? && start_after && objects.first&.name == start_after

      [objects.map { GcsFileWrapper.new(it.name, it.updated.to_time, it.size) }, response.next_page_token]
    rescue Google::Apis::ClientError => ex
      raise unless ex.status_code == 404
      [[].freeze, nil]
    end

    def gcp_list_objects(prefix, delimiter: "", start_after: nil)
      objects = []
      token = nil
      loop do
        page, token = gcp_list_objects_page(prefix, delimiter:, start_after:, token:)
        objects.concat(page)
        break unless token
      end
      objects
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

    def gcp_set_lifecycle_policy(expiration_days: BACKUP_BUCKET_EXPIRATION_DAYS)
      bucket = blob_storage_client.bucket(ubid)
      bucket.lifecycle do |l|
        l.add_delete_rule(age: expiration_days)
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
          raise unless [403, 404].include?(e.status_code)
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

    # Unlike AWS STS/MinIO STS, GCS has no equivalent of "assume an identity, then
    # narrow it via an inline session policy" -- the closest primitives (impersonating
    # a service account, or V4-signed URLs) each need a different design, so this isn't
    # wired up yet.
    def gcp_create_download_credentials(duration_seconds: DOWNLOAD_CREDENTIALS_DURATION_SECONDS)
      fail "Backup download credentials are not supported for GCP-hosted PostgreSQL resources"
    end

    # No standing IAM policy to refresh; GCS access is via service-account credentials.
    def gcp_refresh_blob_storage_policy
    end
  end
end
