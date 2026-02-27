# frozen_string_literal: true

class PostgresServer < Sequel::Model
  module Gcp
    private

    def gcp_add_provider_configs(configs)
      # No GCP-specific Postgres configs needed initially
    end

    def gcp_refresh_walg_blob_storage_credentials
      # Write the per-timeline SA key JSON so WAL-G can use
      # GOOGLE_APPLICATION_CREDENTIALS to access GCS.
      return unless timeline.access_key

      vm.sshable.cmd("sudo -u postgres tee /etc/postgresql/gcs-sa-key.json > /dev/null", stdin: timeline.secret_key)
    end

    def gcp_storage_device_paths
      [vm.vm_storage_volumes.find { it.boot == false }.device_path]
    end

    def gcp_attach_s3_policy_if_needed
      return if timeline.access_key # SA already exists for this timeline

      credential = resource.location.location_credential
      sa_name = "pg-tl-#{timeline.ubid[0..7].downcase}"

      sa_email = "#{sa_name}@#{credential.project_id}.iam.gserviceaccount.com"
      begin
        sa = credential.iam_client.get_project_service_account("projects/#{credential.project_id}/serviceAccounts/#{sa_email}")
      rescue Google::Apis::ClientError
        sa = credential.iam_client.create_service_account(
          "projects/#{credential.project_id}",
          Google::Apis::IamV1::CreateServiceAccountRequest.new(
            account_id: sa_name,
            service_account: Google::Apis::IamV1::ServiceAccount.new(
              display_name: "Postgres timeline #{timeline.ubid}"
            )
          )
        )
      end

      # Grant the parent SA permission to create keys for this child SA.
      # The parent SA may lack project-level iam.serviceAccountKeys.create,
      # so we grant it at the SA resource level instead.
      credential.iam_client.set_service_account_iam_policy(
        sa.name,
        Google::Apis::IamV1::SetIamPolicyRequest.new(
          policy: Google::Apis::IamV1::Policy.new(
            bindings: [Google::Apis::IamV1::Binding.new(
              role: "roles/iam.serviceAccountKeyAdmin",
              members: ["serviceAccount:#{credential.service_account_email}"]
            )]
          )
        )
      )

      # Ensure the GCS bucket exists before setting IAM policy on it.
      # The timeline nexus creates the bucket asynchronously, but during
      # failover/promotion switch_to_new_timeline calls increment_s3_new_timeline
      # before the timeline strand has had a chance to run setup_bucket.
      timeline.create_bucket

      bucket = credential.storage_client.bucket(timeline.ubid)
      policy = bucket.policy requested_policy_version: 3
      policy.bindings.insert(
        role: "roles/storage.objectAdmin",
        members: ["serviceAccount:#{sa.email}"]
      )
      bucket.policy = policy

      key = credential.iam_client.create_service_account_key(sa.name)
      # The google-apis gem auto-decodes base64 fields from the API response,
      # so private_key_data is already raw JSON bytes.
      key_json = key.private_key_data.force_encoding("UTF-8")

      timeline.update(access_key: sa.email, secret_key: key_json)
    end

    def gcp_lockout_mechanisms
      ["pg_stop", "hba"]
    end

    def gcp_increment_s3_new_timeline
      credential = resource.location.location_credential

      # Create SA and bind to new timeline's bucket
      gcp_attach_s3_policy_if_needed

      # Clean up old timeline's SA if it exists
      if (old_timeline = timeline.parent) && old_timeline.access_key
        begin
          credential.iam_client.delete_project_service_account(
            "projects/-/serviceAccounts/#{old_timeline.access_key}"
          )
        rescue Google::Apis::ClientError
          # SA may already be deleted
        end
      end
    end
  end
end

# Table: postgres_server
# Columns:
#  id                     | uuid                     | PRIMARY KEY
#  created_at             | timestamp with time zone | NOT NULL DEFAULT now()
#  resource_id            | uuid                     | NOT NULL
#  vm_id                  | uuid                     |
#  timeline_id            | uuid                     | NOT NULL
#  timeline_access        | timeline_access          | NOT NULL DEFAULT 'push'::timeline_access
#  synchronization_status | synchronization_status   | NOT NULL DEFAULT 'ready'::synchronization_status
#  version                | text                     | NOT NULL
#  physical_slot_ready    | boolean                  | NOT NULL DEFAULT false
#  is_representative      | boolean                  | NOT NULL DEFAULT false
# Indexes:
#  postgres_server_pkey1                             | PRIMARY KEY btree (id)
#  postgres_server_resource_id_is_representative_idx | UNIQUE btree (resource_id) WHERE is_representative IS TRUE
#  postgres_server_resource_id_index                 | btree (resource_id)
# Check constraints:
#  version_check | (version = ANY (ARRAY['16'::text, '17'::text, '18'::text]))
# Foreign key constraints:
#  postgres_server_timeline_id_fkey | (timeline_id) REFERENCES postgres_timeline(id)
#  postgres_server_vm_id_fkey       | (vm_id) REFERENCES vm(id)
