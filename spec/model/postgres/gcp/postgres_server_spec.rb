# frozen_string_literal: true

require_relative "../../spec_helper"

RSpec.describe PostgresServer do
  subject(:postgres_server) {
    described_class.create(
      timeline:, resource:, vm_id: vm.id, is_representative: true,
      synchronization_status: "ready", timeline_access: "push", version: "17",
    )
  }

  let(:project) { Project.create(name: "gcp-pg-test") }

  let(:location) {
    Location.create(
      name: "us-central1",
      display_name: "GCP us-central1",
      ui_name: "GCP US Central 1",
      visible: false,
      provider: "gcp",
    )
  }

  let(:location_credential_gcp) {
    LocationCredentialGcp.create_with_id(location,
      project_id: "test-project",
      service_account_email: "test@test-project.iam.gserviceaccount.com",
      credentials_json: '{"type":"service_account","project_id":"test-project"}')
    resource.location.location_credential_gcp
  }

  let(:timeline) {
    PostgresTimeline.create(
      location_id: location.id,
      access_key: "test-sa@test-project.iam.gserviceaccount.com",
      secret_key: '{"type":"service_account","key":"data"}',
    )
  }

  let(:resource) {
    PostgresResource.create(
      name: "gcp-pg-resource",
      project:,
      location_id: location.id,
      ha_type: PostgresResource::HaType::NONE,
      user_config: {},
      pgbouncer_user_config: {},
      target_version: "17",
      target_vm_size: "standard-2",
      target_storage_size_gib: 64,
      superuser_password: "super",
    )
  }

  let(:vm) {
    create_vm(
      project_id: project.id,
      location_id: location.id,
      name: "gcp-pg-vm",
      memory_gib: 8,
    )
  }

  let(:iam_client) { instance_double(Google::Apis::IamV1::IamService) }
  let(:storage_client) { instance_double(Google::Cloud::Storage::Project) }

  before do
    allow(Config).to receive(:postgres_service_project_id).and_return(project.id)
    location_credential_gcp
  end

  context "with GCP provider" do
    describe "#add_provider_configs" do
      it "does not modify configs" do
        configs = {listen_addresses: "'*'"}
        postgres_server.add_provider_configs(configs)
        expect(configs).to eq({listen_addresses: "'*'"})
      end
    end

    describe "#refresh_walg_blob_storage_credentials" do
      before { Sshable.create_with_id(vm) }

      it "writes SA key JSON to the server" do
        expect(postgres_server.vm.sshable).to receive(:_cmd).with(
          "sudo -u postgres tee /etc/postgresql/gcs-sa-key.json > /dev/null",
          stdin: '{"type":"service_account","key":"data"}',
        )

        postgres_server.refresh_walg_blob_storage_credentials
      end

      it "does nothing when timeline has no access_key" do
        timeline.update(access_key: nil)
        expect(postgres_server.vm).not_to receive(:sshable)
        postgres_server.refresh_walg_blob_storage_credentials
      end
    end

    describe "#storage_device_paths" do
      it "returns data disk device path from vm_storage_volumes" do
        VmStorageVolume.create(vm_id: vm.id, disk_index: 0, size_gib: 10, boot: true)
        VmStorageVolume.create(vm_id: vm.id, disk_index: 1, size_gib: 10, boot: false)

        expect(postgres_server.storage_device_paths).to eq(["/dev/disk/by-id/google-local-nvme-ssd-0"])
      end

      it "returns all non-boot device paths sorted by disk_index" do
        VmStorageVolume.create(vm_id: vm.id, disk_index: 0, size_gib: 10, boot: true)
        VmStorageVolume.create(vm_id: vm.id, disk_index: 2, size_gib: 10, boot: false)
        VmStorageVolume.create(vm_id: vm.id, disk_index: 1, size_gib: 10, boot: false)

        expect(postgres_server.storage_device_paths).to eq([
          "/dev/disk/by-id/google-local-nvme-ssd-0",
          "/dev/disk/by-id/google-local-nvme-ssd-1",
        ])
      end
    end

    describe "#increment_s3_new_timeline" do
      it "increments configure_s3_new_timeline semaphore" do
        Strand.create_with_id(postgres_server, prog: "Postgres::PostgresServerNexus", label: "wait")
        postgres_server.increment_s3_new_timeline
        expect(Semaphore.where(strand_id: postgres_server.id, name: "configure_s3_new_timeline").count).to eq(1)
      end
    end

    describe "#attach_s3_policy_if_needed" do
      it "skips when timeline already has an access_key" do
        expect(location_credential_gcp).not_to receive(:iam_client)
        postgres_server.attach_s3_policy_if_needed
      end

      it "creates SA, ensures bucket exists, binds to bucket IAM, generates key, and stores in timeline" do
        timeline.update(access_key: nil, secret_key: nil)

        sa_resource_name = "projects/test-project/serviceAccounts/pg-tl-abcd1234@test-project.iam.gserviceaccount.com"
        sa = instance_double(Google::Apis::IamV1::ServiceAccount,
          email: "pg-tl-abcd1234@test-project.iam.gserviceaccount.com",
          name: sa_resource_name)
        key = instance_double(Google::Apis::IamV1::ServiceAccountKey,
          private_key_data: '{"type":"service_account","private_key":"pk"}'.b)

        expect(location_credential_gcp).to receive_messages(iam_client:, storage_client:)

        expect(iam_client).to receive(:get_project_service_account).and_raise(
          Google::Apis::ClientError.new("Not Found", status_code: 404),
        )

        expect(Config).to receive(:provider_resource_tag_value).and_return("4242")
        expect(iam_client).to receive(:create_service_account).with(
          "projects/test-project",
          an_instance_of(Google::Apis::IamV1::CreateServiceAccountRequest),
        ) do |_, req|
          expect(req.service_account.description).to include("[Ubicloud=4242]")
          sa
        end
        expect(Clog).to receive(:emit).with("GCP service account created", hash_including(gcp_service_account_created: "pg-tl-abcd1234@test-project.iam.gserviceaccount.com")).and_call_original

        # Fresh service accounts return a Policy with bindings unset (nil),
        # not an empty array. Exercise that path so the || [] fallback is tested.
        empty_policy = Google::Apis::IamV1::Policy.new
        expect(iam_client).to receive(:get_project_service_account_iam_policy).with(sa_resource_name).and_return(empty_policy)
        expect(iam_client).to receive(:set_service_account_iam_policy).with(
          sa_resource_name,
          an_instance_of(Google::Apis::IamV1::SetIamPolicyRequest),
        ) do |_, req|
          binding = req.policy.bindings.find { it.role == "roles/iam.serviceAccountKeyAdmin" }
          expect(binding).not_to be_nil
          expect(binding.members).to include("serviceAccount:test@test-project.iam.gserviceaccount.com")
        end

        expect(timeline).to receive(:create_bucket)

        bucket = instance_double(Google::Cloud::Storage::Bucket)
        policy = instance_double(Google::Cloud::Storage::PolicyV3)
        bindings = instance_double(Google::Cloud::Storage::PolicyV3::Bindings)

        expect(storage_client).to receive(:bucket).with(timeline.ubid).and_return(bucket)
        expect(bucket).to receive(:policy).with(requested_policy_version: 3).and_return(policy)
        expect(policy).to receive(:bindings).and_return(bindings)
        expect(bindings).to receive(:insert).with(
          role: "roles/storage.objectAdmin",
          members: ["serviceAccount:pg-tl-abcd1234@test-project.iam.gserviceaccount.com"],
        )
        expect(bucket).to receive(:policy=).with(policy)

        expect(iam_client).to receive(:create_service_account_key).with(
          sa_resource_name,
        ).and_return(key)

        postgres_server.attach_s3_policy_if_needed

        timeline.reload
        expect(timeline.access_key).to eq("pg-tl-abcd1234@test-project.iam.gserviceaccount.com")
        expect(timeline.secret_key).to eq('{"type":"service_account","private_key":"pk"}')
      end

      it "re-raises non-404 errors from get_project_service_account" do
        timeline.update(access_key: nil, secret_key: nil)

        expect(location_credential_gcp).to receive(:iam_client).and_return(iam_client)

        expect(iam_client).to receive(:get_project_service_account).and_raise(
          Google::Apis::ClientError.new("Forbidden", status_code: 403),
        )
        expect(iam_client).not_to receive(:create_service_account)

        expect { postgres_server.attach_s3_policy_if_needed }.to raise_error(Google::Apis::ClientError, /Forbidden/)
      end

      it "uses existing SA when get_project_service_account succeeds" do
        timeline.update(access_key: nil, secret_key: nil)

        sa_resource_name = "projects/test-project/serviceAccounts/pg-tl-abcd1234@test-project.iam.gserviceaccount.com"
        sa = instance_double(Google::Apis::IamV1::ServiceAccount,
          email: "pg-tl-abcd1234@test-project.iam.gserviceaccount.com",
          name: sa_resource_name)
        key = instance_double(Google::Apis::IamV1::ServiceAccountKey,
          private_key_data: '{"type":"service_account","private_key":"pk"}'.b)

        expect(location_credential_gcp).to receive_messages(iam_client:, storage_client:)

        # SA already exists: get succeeds.
        expect(iam_client).to receive(:get_project_service_account).and_return(sa)
        expect(iam_client).not_to receive(:create_service_account)
        # Even on the existing-SA path, emit the email so a partial-restart
        # caller surfaces the name to e2e cleanup's grep.
        expect(Clog).to receive(:emit).with("GCP service account created", hash_including(gcp_service_account_created: "pg-tl-abcd1234@test-project.iam.gserviceaccount.com")).and_call_original

        empty_policy = Google::Apis::IamV1::Policy.new(bindings: [])
        expect(iam_client).to receive(:get_project_service_account_iam_policy).with(sa_resource_name).and_return(empty_policy)
        expect(iam_client).to receive(:set_service_account_iam_policy)
        expect(timeline).to receive(:create_bucket)

        bucket = instance_double(Google::Cloud::Storage::Bucket)
        policy = instance_double(Google::Cloud::Storage::PolicyV3)
        bindings = instance_double(Google::Cloud::Storage::PolicyV3::Bindings)
        expect(storage_client).to receive(:bucket).with(timeline.ubid).and_return(bucket)
        expect(bucket).to receive(:policy).with(requested_policy_version: 3).and_return(policy)
        expect(policy).to receive(:bindings).and_return(bindings)
        expect(bindings).to receive(:insert)
        expect(bucket).to receive(:policy=).with(policy)

        expect(iam_client).to receive(:create_service_account_key).with(sa_resource_name).and_return(key)

        postgres_server.attach_s3_policy_if_needed

        timeline.reload
        expect(timeline.access_key).to eq("pg-tl-abcd1234@test-project.iam.gserviceaccount.com")
      end

      it "preserves existing bindings on SA IAM policy and does not duplicate members" do
        timeline.update(access_key: nil, secret_key: nil)

        sa_resource_name = "projects/test-project/serviceAccounts/pg-tl-abcd1234@test-project.iam.gserviceaccount.com"
        sa = instance_double(Google::Apis::IamV1::ServiceAccount,
          email: "pg-tl-abcd1234@test-project.iam.gserviceaccount.com",
          name: sa_resource_name)
        key = instance_double(Google::Apis::IamV1::ServiceAccountKey,
          private_key_data: '{"type":"service_account","private_key":"pk"}'.b)

        expect(location_credential_gcp).to receive_messages(iam_client:, storage_client:)

        expect(iam_client).to receive(:get_project_service_account).and_return(sa)

        # Existing policy already has the target binding (retry scenario) plus another binding
        existing_policy = Google::Apis::IamV1::Policy.new(bindings: [
          Google::Apis::IamV1::Binding.new(
            role: "roles/iam.serviceAccountKeyAdmin",
            members: ["serviceAccount:test@test-project.iam.gserviceaccount.com"],
          ),
          Google::Apis::IamV1::Binding.new(
            role: "roles/viewer",
            members: ["serviceAccount:other@test-project.iam.gserviceaccount.com"],
          ),
        ])
        expect(iam_client).to receive(:get_project_service_account_iam_policy).with(sa_resource_name).and_return(existing_policy)
        expect(iam_client).to receive(:set_service_account_iam_policy).with(
          sa_resource_name,
          an_instance_of(Google::Apis::IamV1::SetIamPolicyRequest),
        ) do |_, req|
          # Should preserve both bindings and not duplicate the member
          key_admin = req.policy.bindings.find { it.role == "roles/iam.serviceAccountKeyAdmin" }
          viewer = req.policy.bindings.find { it.role == "roles/viewer" }
          expect(key_admin.members).to eq(["serviceAccount:test@test-project.iam.gserviceaccount.com"])
          expect(viewer.members).to eq(["serviceAccount:other@test-project.iam.gserviceaccount.com"])
        end

        expect(timeline).to receive(:create_bucket)

        bucket = instance_double(Google::Cloud::Storage::Bucket)
        policy = instance_double(Google::Cloud::Storage::PolicyV3)
        bindings = instance_double(Google::Cloud::Storage::PolicyV3::Bindings)
        expect(storage_client).to receive(:bucket).with(timeline.ubid).and_return(bucket)
        expect(bucket).to receive(:policy).with(requested_policy_version: 3).and_return(policy)
        expect(policy).to receive(:bindings).and_return(bindings)
        expect(bindings).to receive(:insert)
        expect(bucket).to receive(:policy=).with(policy)

        expect(iam_client).to receive(:create_service_account_key).with(sa_resource_name).and_return(key)

        postgres_server.attach_s3_policy_if_needed
      end

      it "adds member to existing role binding when member is absent" do
        timeline.update(access_key: nil, secret_key: nil)

        sa_resource_name = "projects/test-project/serviceAccounts/pg-tl-abcd1234@test-project.iam.gserviceaccount.com"
        sa = instance_double(Google::Apis::IamV1::ServiceAccount,
          email: "pg-tl-abcd1234@test-project.iam.gserviceaccount.com",
          name: sa_resource_name)
        key = instance_double(Google::Apis::IamV1::ServiceAccountKey,
          private_key_data: '{"type":"service_account","private_key":"pk"}'.b)

        expect(location_credential_gcp).to receive_messages(iam_client:, storage_client:)

        expect(iam_client).to receive(:get_project_service_account).and_return(sa)

        # Existing policy has the role but with a DIFFERENT member
        existing_policy = Google::Apis::IamV1::Policy.new(bindings: [
          Google::Apis::IamV1::Binding.new(
            role: "roles/iam.serviceAccountKeyAdmin",
            members: ["serviceAccount:other@test-project.iam.gserviceaccount.com"],
          ),
        ])
        expect(iam_client).to receive(:get_project_service_account_iam_policy).with(sa_resource_name).and_return(existing_policy)
        expect(iam_client).to receive(:set_service_account_iam_policy).with(
          sa_resource_name,
          an_instance_of(Google::Apis::IamV1::SetIamPolicyRequest),
        ) do |_, req|
          binding = req.policy.bindings.find { it.role == "roles/iam.serviceAccountKeyAdmin" }
          expect(binding.members).to contain_exactly(
            "serviceAccount:other@test-project.iam.gserviceaccount.com",
            "serviceAccount:test@test-project.iam.gserviceaccount.com",
          )
        end

        expect(timeline).to receive(:create_bucket)

        bucket = instance_double(Google::Cloud::Storage::Bucket)
        policy = instance_double(Google::Cloud::Storage::PolicyV3)
        bindings = instance_double(Google::Cloud::Storage::PolicyV3::Bindings)
        expect(storage_client).to receive(:bucket).with(timeline.ubid).and_return(bucket)
        expect(bucket).to receive(:policy).with(requested_policy_version: 3).and_return(policy)
        expect(policy).to receive(:bindings).and_return(bindings)
        expect(bindings).to receive(:insert)
        expect(bucket).to receive(:policy=).with(policy)

        expect(iam_client).to receive(:create_service_account_key).with(sa_resource_name).and_return(key)

        postgres_server.attach_s3_policy_if_needed
      end

      context "with old timeline SA cleanup" do
        let(:new_sa) {
          instance_double(Google::Apis::IamV1::ServiceAccount,
            email: "pg-tl-newsa123@test-project.iam.gserviceaccount.com",
            name: "projects/test-project/serviceAccounts/pg-tl-newsa123@test-project.iam.gserviceaccount.com")
        }

        let(:new_key) {
          instance_double(Google::Apis::IamV1::ServiceAccountKey,
            private_key_data: '{"type":"service_account","private_key":"new"}'.b)
        }

        before do
          allow(location_credential_gcp).to receive_messages(iam_client:, storage_client:)

          bucket = instance_double(Google::Cloud::Storage::Bucket)
          policy = instance_double(Google::Cloud::Storage::PolicyV3)
          bindings = instance_double(Google::Cloud::Storage::PolicyV3::Bindings)
          allow(storage_client).to receive_messages(create_bucket: bucket, bucket:)
          allow(bucket).to receive(:policy).and_return(policy)
          allow(policy).to receive(:bindings).and_return(bindings)
          allow(bindings).to receive(:insert)
          allow(bucket).to receive(:policy=)
          allow(timeline).to receive(:create_bucket)

          allow(iam_client).to receive(:get_project_service_account_iam_policy).and_return(Google::Apis::IamV1::Policy.new(bindings: []))
          allow(iam_client).to receive(:set_service_account_iam_policy)
          allow(iam_client).to receive(:get_project_service_account).and_raise(Google::Apis::ClientError.new("Not Found", status_code: 404))
          allow(iam_client).to receive_messages(create_service_account: new_sa, create_service_account_key: new_key)
        end

        it "deletes old timeline's SA when parent timeline has access_key" do
          parent_timeline = PostgresTimeline.create(
            location_id: location.id,
            access_key: "old-sa@test-project.iam.gserviceaccount.com",
            secret_key: '{"type":"service_account","key":"old"}',
          )
          timeline.update(access_key: nil, secret_key: nil, parent_id: parent_timeline.id)

          expect(iam_client).to receive(:delete_project_service_account).with(
            "projects/-/serviceAccounts/old-sa@test-project.iam.gserviceaccount.com",
          )

          postgres_server.attach_s3_policy_if_needed
        end

        it "does not delete old SA when parent timeline has no access_key" do
          parent_timeline = PostgresTimeline.create(
            location_id: location.id,
            access_key: nil,
            secret_key: nil,
          )
          timeline.update(access_key: nil, secret_key: nil, parent_id: parent_timeline.id)

          expect(iam_client).not_to receive(:delete_project_service_account)

          postgres_server.attach_s3_policy_if_needed
        end

        it "ignores errors when deleting an already-deleted SA" do
          parent_timeline = PostgresTimeline.create(
            location_id: location.id,
            access_key: "deleted-sa@test-project.iam.gserviceaccount.com",
            secret_key: '{"type":"service_account","key":"old"}',
          )
          timeline.update(access_key: nil, secret_key: nil, parent_id: parent_timeline.id)

          expect(iam_client).to receive(:delete_project_service_account).and_raise(
            Google::Apis::ClientError.new("Not Found", status_code: 404),
          )

          postgres_server.attach_s3_policy_if_needed
        end

        it "re-raises non-404 errors when deleting old SA" do
          parent_timeline = PostgresTimeline.create(
            location_id: location.id,
            access_key: "broken-sa@test-project.iam.gserviceaccount.com",
            secret_key: '{"type":"service_account","key":"old"}',
          )
          timeline.update(access_key: nil, secret_key: nil, parent_id: parent_timeline.id)

          expect(iam_client).to receive(:delete_project_service_account).and_raise(
            Google::Apis::ClientError.new("Forbidden", status_code: 403),
          )

          expect { postgres_server.attach_s3_policy_if_needed }.to raise_error(Google::Apis::ClientError, /Forbidden/)
        end

        it "does not attempt to delete when there is no parent timeline" do
          timeline.update(access_key: nil, secret_key: nil)

          expect(iam_client).not_to receive(:delete_project_service_account)

          postgres_server.attach_s3_policy_if_needed
        end
      end
    end
  end
end
