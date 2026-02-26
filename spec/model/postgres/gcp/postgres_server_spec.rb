# frozen_string_literal: true

require_relative "../../spec_helper"

RSpec.describe PostgresServer do
  subject(:postgres_server) {
    described_class.create(
      timeline:, resource:, vm_id: vm.id, is_representative: true,
      synchronization_status: "ready", timeline_access: "push", version: "17"
    )
  }

  let(:project) { Project.create(name: "gcp-pg-test") }

  let(:location) {
    Location.create(
      name: "us-central1",
      display_name: "GCP us-central1",
      ui_name: "GCP US Central 1",
      visible: false,
      provider: "gcp"
    )
  }

  let(:location_credential) {
    LocationCredential.create_with_id(location.id,
      project_id: "test-project",
      service_account_email: "test@test-project.iam.gserviceaccount.com",
      credentials_json: '{"type":"service_account","project_id":"test-project"}')
  }

  let(:timeline) {
    PostgresTimeline.create(
      location:,
      access_key: "test-sa@test-project.iam.gserviceaccount.com",
      secret_key: '{"type":"service_account","key":"data"}'
    )
  }

  let(:resource) {
    PostgresResource.create(
      name: "gcp-pg-resource",
      project:,
      location:,
      ha_type: PostgresResource::HaType::NONE,
      user_config: {},
      pgbouncer_user_config: {},
      target_version: "17",
      target_vm_size: "standard-2",
      target_storage_size_gib: 64,
      superuser_password: "super"
    )
  }

  let(:vm) {
    create_vm(
      project_id: project.id,
      location_id: location.id,
      name: "gcp-pg-vm",
      memory_gib: 8
    )
  }

  let(:iam_client) { instance_double(Google::Apis::IamV1::IamService) }
  let(:storage_client) { instance_double(Google::Cloud::Storage::Project) }

  before do
    location_credential
    allow(Config).to receive(:postgres_service_project_id).and_return(project.id)
    resource # force creation
    allow(resource.location).to receive(:location_credential).and_return(location_credential)
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
      before { Sshable.create_with_id(vm.id) }

      it "writes SA key JSON to the server" do
        expect(postgres_server.vm.sshable).to receive(:_cmd).with(
          "sudo -u postgres tee /etc/postgresql/gcs-sa-key.json > /dev/null",
          stdin: '{"type":"service_account","key":"data"}'
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
        boot_vol = instance_double(VmStorageVolume, boot: true)
        data_vol = instance_double(VmStorageVolume, boot: false, device_path: "/dev/vdb")
        expect(postgres_server.vm).to receive(:vm_storage_volumes).and_return([boot_vol, data_vol])

        expect(postgres_server.storage_device_paths).to eq(["/dev/vdb"])
      end
    end

    describe "#lockout_mechanisms" do
      it "returns pg_stop and hba" do
        expect(postgres_server.lockout_mechanisms).to eq(["pg_stop", "hba"])
      end
    end

    describe "#attach_s3_policy_if_needed" do
      it "skips when timeline already has an access_key" do
        expect(location_credential).not_to receive(:iam_client)
        postgres_server.attach_s3_policy_if_needed
      end

      it "creates SA, ensures bucket exists, binds to bucket IAM, generates key, and stores in timeline" do
        timeline.update(access_key: nil, secret_key: nil)

        sa_resource_name = "projects/test-project/serviceAccounts/pg-tl-abcd1234@test-project.iam.gserviceaccount.com"
        sa = instance_double(Google::Apis::IamV1::ServiceAccount,
          email: "pg-tl-abcd1234@test-project.iam.gserviceaccount.com",
          name: sa_resource_name)
        key = instance_double(Google::Apis::IamV1::ServiceAccountKey,
          private_key_data: '{"type":"service_account","private_key":"pk"}'.dup.force_encoding("ASCII-8BIT"))

        allow(location_credential).to receive_messages(iam_client:, storage_client:)

        expect(iam_client).to receive(:get_project_service_account).and_raise(
          Google::Apis::ClientError.new("Not Found")
        )

        expect(iam_client).to receive(:create_service_account).with(
          "projects/test-project",
          an_instance_of(Google::Apis::IamV1::CreateServiceAccountRequest)
        ).and_return(sa)

        expect(iam_client).to receive(:set_service_account_iam_policy).with(
          sa_resource_name,
          an_instance_of(Google::Apis::IamV1::SetIamPolicyRequest)
        )

        expect(timeline).to receive(:create_bucket)

        bucket = instance_double(Google::Cloud::Storage::Bucket)
        policy = instance_double(Google::Cloud::Storage::PolicyV3)
        bindings = instance_double(Google::Cloud::Storage::PolicyV3::Bindings)

        expect(storage_client).to receive(:bucket).with(timeline.ubid).and_return(bucket)
        expect(bucket).to receive(:policy).with(requested_policy_version: 3).and_return(policy)
        expect(policy).to receive(:bindings).and_return(bindings)
        expect(bindings).to receive(:insert).with(
          role: "roles/storage.objectAdmin",
          members: ["serviceAccount:pg-tl-abcd1234@test-project.iam.gserviceaccount.com"]
        )
        expect(bucket).to receive(:policy=).with(policy)

        expect(iam_client).to receive(:create_service_account_key).with(
          sa_resource_name
        ).and_return(key)

        postgres_server.attach_s3_policy_if_needed

        timeline.reload
        expect(timeline.access_key).to eq("pg-tl-abcd1234@test-project.iam.gserviceaccount.com")
        expect(timeline.secret_key).to eq('{"type":"service_account","private_key":"pk"}')
      end

      it "uses existing SA when get_project_service_account succeeds" do
        timeline.update(access_key: nil, secret_key: nil)

        sa_resource_name = "projects/test-project/serviceAccounts/pg-tl-abcd1234@test-project.iam.gserviceaccount.com"
        sa = instance_double(Google::Apis::IamV1::ServiceAccount,
          email: "pg-tl-abcd1234@test-project.iam.gserviceaccount.com",
          name: sa_resource_name)
        key = instance_double(Google::Apis::IamV1::ServiceAccountKey,
          private_key_data: '{"type":"service_account","private_key":"pk"}'.dup.force_encoding("ASCII-8BIT"))

        allow(location_credential).to receive_messages(iam_client:, storage_client:)

        # SA already exists — get succeeds
        expect(iam_client).to receive(:get_project_service_account).and_return(sa)
        expect(iam_client).not_to receive(:create_service_account)

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
    end

    describe "#increment_s3_new_timeline" do
      let(:sa_resource_name) { "projects/test-project/serviceAccounts/pg-tl-newsa123@test-project.iam.gserviceaccount.com" }

      let(:sa) {
        instance_double(Google::Apis::IamV1::ServiceAccount,
          email: "pg-tl-newsa123@test-project.iam.gserviceaccount.com",
          name: sa_resource_name)
      }

      let(:key) {
        instance_double(Google::Apis::IamV1::ServiceAccountKey,
          private_key_data: '{"type":"service_account","private_key":"new"}'.dup.force_encoding("ASCII-8BIT"))
      }

      before do
        allow(location_credential).to receive_messages(iam_client:, storage_client:)

        bucket = instance_double(Google::Cloud::Storage::Bucket)
        policy = instance_double(Google::Cloud::Storage::PolicyV3)
        bindings = instance_double(Google::Cloud::Storage::PolicyV3::Bindings)
        allow(storage_client).to receive_messages(create_bucket: bucket, bucket:)
        allow(bucket).to receive(:policy).and_return(policy)
        allow(policy).to receive(:bindings).and_return(bindings)
        allow(bindings).to receive(:insert)
        allow(bucket).to receive(:policy=)

        allow(iam_client).to receive(:set_service_account_iam_policy)
        allow(iam_client).to receive(:get_project_service_account).and_raise(Google::Apis::ClientError.new("Not Found"))
        allow(iam_client).to receive_messages(create_service_account: sa, create_service_account_key: key)
      end

      it "creates SA for the new timeline and deletes the old timeline's SA" do
        parent_timeline = PostgresTimeline.create(
          location:,
          access_key: "old-sa@test-project.iam.gserviceaccount.com",
          secret_key: '{"type":"service_account","key":"old"}'
        )
        timeline.update(access_key: nil, secret_key: nil, parent_id: parent_timeline.id)

        expect(iam_client).to receive(:delete_project_service_account).with(
          "projects/-/serviceAccounts/old-sa@test-project.iam.gserviceaccount.com"
        )

        postgres_server.increment_s3_new_timeline
      end

      it "does not delete old SA when parent timeline has no access_key" do
        parent_timeline = PostgresTimeline.create(
          location:,
          access_key: nil,
          secret_key: nil
        )
        timeline.update(access_key: nil, secret_key: nil, parent_id: parent_timeline.id)

        expect(iam_client).not_to receive(:delete_project_service_account)

        postgres_server.increment_s3_new_timeline
      end

      it "ignores errors when deleting an already-deleted SA" do
        parent_timeline = PostgresTimeline.create(
          location:,
          access_key: "deleted-sa@test-project.iam.gserviceaccount.com",
          secret_key: '{"type":"service_account","key":"old"}'
        )
        timeline.update(access_key: nil, secret_key: nil, parent_id: parent_timeline.id)

        expect(iam_client).to receive(:delete_project_service_account).and_raise(
          Google::Apis::ClientError.new("Not Found")
        )

        expect { postgres_server.increment_s3_new_timeline }.not_to raise_error
      end

      it "does not attempt to delete when there is no parent timeline" do
        timeline.update(access_key: nil, secret_key: nil)

        expect(iam_client).not_to receive(:delete_project_service_account)

        postgres_server.increment_s3_new_timeline
      end
    end
  end
end
