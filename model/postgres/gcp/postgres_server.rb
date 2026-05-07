# frozen_string_literal: true

class PostgresServer < Sequel::Model
  module Gcp
    private

    def gcp_add_provider_configs(configs)
      # No GCP-specific Postgres configs needed initially
      nil
    end

    def gcp_refresh_walg_blob_storage_credentials
      # Write the per-timeline SA key JSON so WAL-G can use
      # GOOGLE_APPLICATION_CREDENTIALS to access GCS.
      return unless timeline.access_key

      vm.sshable.write_file("/etc/postgresql/gcs-sa-key.json", timeline.secret_key, user: "postgres")
    end

    def gcp_storage_device_paths
      vm.vm_storage_volumes.reject(&:boot).sort_by!(&:disk_index).map!(&:device_path)
    end

    def gcp_attach_s3_policy_if_needed
      return if timeline.access_key # service account already exists for this timeline

      credential = resource.location.location_credential_gcp
      service_account_name = "pg-tl-#{timeline.ubid[0..7]}"
      service_account_email = "#{service_account_name}@#{credential.project_id}.iam.gserviceaccount.com"
      begin
        service_account = credential.iam_client.get_project_service_account("projects/#{credential.project_id}/serviceAccounts/#{service_account_email}")
      rescue Google::Apis::ClientError => e
        raise unless e.status_code == 404
        service_account = credential.iam_client.create_service_account(
          "projects/#{credential.project_id}",
          Google::Apis::IamV1::CreateServiceAccountRequest.new(
            account_id: service_account_name,
            service_account: Google::Apis::IamV1::ServiceAccount.new(
              display_name: "Postgres timeline #{timeline.ubid}",
              description: "Ubicloud postgres timeline service account [Ubicloud=#{Config.provider_resource_tag_value}]",
            ),
          ),
        )
      end
      # Emit on both branches: a partial-restart caller that re-enters
      # this method and finds the SA already present must still surface
      # the email so e2e cleanup can grep it out of foreman.log.
      Clog.emit("GCP service account created",
        {gcp_service_account_created: service_account.email})

      # Grant the parent service account permission to create keys for this
      # child service account. The parent may lack project-level
      # iam.serviceAccountKeys.create, so we grant it at the service account
      # resource level instead. Read-modify-write to preserve any existing
      # bindings (e.g. on retry).
      target_role = "roles/iam.serviceAccountKeyAdmin"
      target_member = "serviceAccount:#{credential.service_account_email}"
      existing_policy = credential.iam_client.get_project_service_account_iam_policy(service_account.name)
      bindings = existing_policy.bindings || []
      role_binding = bindings.find { it.role == target_role }
      if role_binding
        role_binding.members << target_member unless role_binding.members.include?(target_member)
      else
        bindings << Google::Apis::IamV1::Binding.new(role: target_role, members: [target_member])
      end
      existing_policy.bindings = bindings
      credential.iam_client.set_service_account_iam_policy(
        service_account.name,
        Google::Apis::IamV1::SetIamPolicyRequest.new(policy: existing_policy),
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
        members: ["serviceAccount:#{service_account.email}"],
      )
      bucket.policy = policy

      key = credential.iam_client.create_service_account_key(service_account.name)
      # The google-apis gem auto-decodes base64 fields from the API response,
      # so private_key_data is already raw JSON bytes.
      key_json = key.private_key_data.force_encoding("UTF-8")

      timeline.update(access_key: service_account.email, secret_key: key_json)

      # Clean up old timeline's service account if it exists. Best-effort, runs after
      # timeline.update so retries won't re-enter (access_key guard above).
      cleanup_old_timeline_service_account(credential)
    end

    def cleanup_old_timeline_service_account(credential)
      if (old_timeline = timeline.parent) && old_timeline.access_key
        begin
          credential.iam_client.delete_project_service_account(
            "projects/-/serviceAccounts/#{old_timeline.access_key}",
          )
        rescue Google::Apis::ClientError => e
          raise unless e.status_code == 404
          nil
        end
      end
    end

    def gcp_increment_s3_new_timeline
      incr_configure_s3_new_timeline
    end
  end
end
