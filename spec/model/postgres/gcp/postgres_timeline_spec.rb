# frozen_string_literal: true

require_relative "../../spec_helper"

RSpec.describe PostgresTimeline do
  subject(:postgres_timeline) {
    described_class.create(
      access_key: "test-sa@test-project.iam.gserviceaccount.com",
      secret_key: '{"type":"service_account"}',
      location_id: location.id,
    )
  }

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
  }

  before do
    location_credential_gcp
  end

  context "with GCP provider" do
    describe "#generate_walg_config" do
      it "returns GCS walg config with the credentials line when access_key is set" do
        walg_config = <<-WALG_CONF
WALG_GS_PREFIX=gs://#{postgres_timeline.ubid}
GOOGLE_APPLICATION_CREDENTIALS=/etc/postgresql/gcs-sa-key.json

PGHOST=/var/run/postgresql
PGDATA=/dat/17/data
        WALG_CONF

        expect(postgres_timeline.generate_walg_config(17, instance_double(PostgresServer))).to eq(walg_config)
      end

      it "omits the credentials line when access_key is nil so WAL-G uses metadata-server ADC" do
        postgres_timeline.update(access_key: nil, secret_key: nil)
        walg_config = <<-WALG_CONF
WALG_GS_PREFIX=gs://#{postgres_timeline.ubid}

PGHOST=/var/run/postgresql
PGDATA=/dat/17/data
        WALG_CONF

        expect(postgres_timeline.generate_walg_config(17, instance_double(PostgresServer))).to eq(walg_config)
      end

      it "appends the hardware-sized config on local-SSD instances when enabled" do
        allow(postgres_timeline).to receive(:leader).and_return(instance_double(PostgresServer,
          resource: instance_double(PostgresResource, project: instance_double(Project, get_ff_postgres_walg_optimized_config_disabled: false, get_ff_postgres_walg_direct_io_disabled: false))))
        server = instance_double(PostgresServer, vm: instance_double(Vm, vcpus: 8, memory_gib: 32),
          storage_device_paths: ["/dev/nvme0n1", "/dev/nvme1n1"],
          resource: instance_double(PostgresResource, target_vm_size: "c4a-standard-8"))

        config = postgres_timeline.generate_walg_config(17, server)
        expect(config).to include("WALG_UPLOAD_DISK_CONCURRENCY=4")   # floor(0.50*8)
        expect(config).to include("WALG_DIRECT_IO=true")
        expect(config).to include("WALG_DIRECT_IO_BLOCK_COUNT=512")   # 2 local SSDs * 256
      end

      it "leaves stock config (no hardware knobs) when the server has no vm yet" do
        allow(postgres_timeline).to receive(:leader).and_return(instance_double(PostgresServer,
          resource: instance_double(PostgresResource, project: instance_double(Project, get_ff_postgres_walg_optimized_config_disabled: nil))))

        expect(postgres_timeline.generate_walg_config(17, instance_double(PostgresServer, vm: nil))).not_to include("WALG_UPLOAD_DISK_CONCURRENCY")
      end
    end

    describe "#walg_config_region" do
      it "returns the location name" do
        expect(postgres_timeline.walg_config_region).to eq("us-central1")
      end
    end

    describe "#blob_storage" do
      it "returns a GcsBlobStorage with the GCS endpoint URL" do
        bs = postgres_timeline.blob_storage
        expect(bs).to be_a(PostgresTimeline::GcsBlobStorage)
        expect(bs.url).to eq("https://storage.googleapis.com")
      end
    end

    describe "#blob_storage_client" do
      it "returns the storage client from the location credential" do
        storage_client = instance_double(Google::Cloud::Storage::Project)
        lcg = instance_double(LocationCredentialGcp, storage_client:)
        expect(postgres_timeline).to receive(:location).and_return(instance_double(Location, location_credential_gcp: lcg, name: "us-central1", provider_dispatcher_group_name: "gcp")).at_least(:once)
        expect(postgres_timeline.blob_storage_client).to eq(storage_client)
      end
    end

    describe "#list_objects" do
      let(:storage_api) { instance_double(Google::Apis::StorageV1::StorageService) }

      before do
        allow(Google::Auth::ServiceAccountCredentials).to receive(:make_creds).and_return(nil)
        allow(Google::Apis::StorageV1::StorageService).to receive(:new).and_return(storage_api)
        allow(storage_api).to receive(:authorization=)
      end

      def gcs_object(name, size: 100, updated: Time.now)
        instance_double(Google::Apis::StorageV1::Object, name:, size:, updated:)
      end

      def gcs_page(items, next_page_token: nil)
        instance_double(Google::Apis::StorageV1::Objects, items:, next_page_token:)
      end

      it "returns wrapped objects with key, last_modified and size" do
        updated = Time.now
        expect(storage_api).to receive(:list_objects).with(postgres_timeline.ubid, prefix: "basebackups_005/",
          delimiter: nil, start_offset: nil, page_token: nil, max_results: 1000)
          .and_return(gcs_page([gcs_object("basebackups_005/0001_backup_stop_sentinel.json", size: 42, updated:)]))

        objects = postgres_timeline.list_objects("basebackups_005/")
        expect(objects.length).to eq(1)
        expect(objects.first.key).to eq("basebackups_005/0001_backup_stop_sentinel.json")
        expect(objects.first.size).to eq(42)
        expect(objects.first.last_modified).to eq(updated.to_time)
      end

      it "returns empty array when the bucket does not exist" do
        expect(storage_api).to receive(:list_objects).once
          .and_raise(Google::Apis::ClientError.new("notFound", status_code: 404))

        expect(postgres_timeline.list_objects("prefix/")).to eq([])
      end

      it "re-raises client errors other than a missing bucket" do
        expect(storage_api).to receive(:list_objects).once
          .and_raise(Google::Apis::ClientError.new("forbidden", status_code: 403))

        expect { postgres_timeline.list_objects("prefix/") }.to raise_error(Google::Apis::ClientError)
      end

      it "follows pagination and passes the delimiter through" do
        expect(storage_api).to receive(:list_objects).with(postgres_timeline.ubid, prefix: "prefix/", delimiter: "/",
          start_offset: nil, page_token: nil, max_results: 1000)
          .and_return(gcs_page([gcs_object("file1")], next_page_token: "next-page"))
        expect(storage_api).to receive(:list_objects).with(postgres_timeline.ubid, prefix: "prefix/", delimiter: "/",
          start_offset: nil, page_token: "next-page", max_results: 1000)
          .and_return(gcs_page([gcs_object("file2")]))

        expect(postgres_timeline.list_objects("prefix/", delimiter: "/").map(&:key)).to eq(["file1", "file2"])
      end

      it "drops the cursor object, because startOffset is inclusive" do
        expect(storage_api).to receive(:list_objects).with(postgres_timeline.ubid, prefix: "wal_005/", delimiter: nil,
          start_offset: "wal_005/a", page_token: nil, max_results: 1000)
          .and_return(gcs_page([gcs_object("wal_005/a"), gcs_object("wal_005/b")]))

        expect(postgres_timeline.list_objects("wal_005/", start_after: "wal_005/a").map(&:key)).to eq(["wal_005/b"])
      end

      it "keeps the first object when it is past the cursor" do
        expect(storage_api).to receive(:list_objects).with(postgres_timeline.ubid, prefix: "wal_005/", delimiter: nil,
          start_offset: "wal_005/a", page_token: nil, max_results: 1000)
          .and_return(gcs_page([gcs_object("wal_005/b"), gcs_object("wal_005/c")]))

        expect(postgres_timeline.list_objects("wal_005/", start_after: "wal_005/a").map(&:key)).to eq(["wal_005/b", "wal_005/c"])
      end

      it "tolerates a bucket with no objects" do
        expect(storage_api).to receive(:list_objects).once.and_return(gcs_page(nil))

        expect(postgres_timeline.list_objects("wal_005/", start_after: "wal_005/a")).to eq([])
      end
    end

    describe "#list_objects_page" do
      let(:storage_api) { instance_double(Google::Apis::StorageV1::StorageService) }

      before do
        allow(Google::Auth::ServiceAccountCredentials).to receive(:make_creds).and_return(nil)
        allow(Google::Apis::StorageV1::StorageService).to receive(:new).and_return(storage_api)
        allow(storage_api).to receive(:authorization=)
      end

      def gcs_object(name, size: 100, updated: Time.now)
        instance_double(Google::Apis::StorageV1::Object, name:, size:, updated:)
      end

      def gcs_page(items, next_page_token: nil)
        instance_double(Google::Apis::StorageV1::Objects, items:, next_page_token:)
      end

      it "returns one page and its token without following it" do
        expect(storage_api).to receive(:list_objects).once.with(postgres_timeline.ubid, prefix: "wal_005/",
          delimiter: nil, start_offset: nil, page_token: nil, max_results: 1000)
          .and_return(gcs_page([gcs_object("wal_005/a")], next_page_token: "next-page"))

        objects, token = postgres_timeline.list_objects_page("wal_005/")
        expect(objects.map(&:key)).to eq(["wal_005/a"])
        expect(token).to eq("next-page")
      end

      it "keeps the cursor object on a continuation page, and sends no offset with a token" do
        expect(storage_api).to receive(:list_objects).with(postgres_timeline.ubid, prefix: "wal_005/",
          delimiter: nil, start_offset: nil, page_token: "next-page", max_results: 1000)
          .and_return(gcs_page([gcs_object("wal_005/a"), gcs_object("wal_005/b")]))

        objects, token = postgres_timeline.list_objects_page("wal_005/", start_after: "wal_005/a", token: "next-page")
        expect(objects.map(&:key)).to eq(["wal_005/a", "wal_005/b"])
        expect(token).to be_nil
      end

      it "returns an empty page when the bucket does not exist" do
        expect(storage_api).to receive(:list_objects).once
          .and_raise(Google::Apis::ClientError.new("notFound", status_code: 404))

        expect(postgres_timeline.list_objects_page("wal_005/")).to eq([[], nil])
      end
    end

    describe "#create_bucket" do
      it "creates a GCS bucket with uniform bucket level access and ubicloud label" do
        expect(Config).to receive(:provider_resource_tag_value).and_return("12321")
        storage_client = instance_double(Google::Cloud::Storage::Project)
        expect(postgres_timeline).to receive(:blob_storage_client).and_return(storage_client)

        expect(storage_client).to receive(:create_bucket).with(postgres_timeline.ubid, location: "us-central1").and_yield(
          instance_double(Google::Cloud::Storage::Bucket::Updater).tap do |b|
            expect(b).to receive(:uniform_bucket_level_access=).with(true)
            expect(b).to receive(:labels=).with({"ubicloud" => "12321"})
          end,
        )
        expect(Clog).to receive(:emit).with("GCP GCS bucket created", hash_including(gcp_gcs_bucket_created: postgres_timeline.ubid)).and_call_original

        postgres_timeline.create_bucket
      end

      it "ignores AlreadyExistsError but still emits so cleanup grep picks the bucket up" do
        storage_client = instance_double(Google::Cloud::Storage::Project)
        expect(postgres_timeline).to receive(:blob_storage_client).and_return(storage_client)
        expect(storage_client).to receive(:create_bucket).and_raise(Google::Cloud::AlreadyExistsError.new("already exists"))
        expect(Clog).to receive(:emit).with("GCP GCS bucket created", hash_including(gcp_gcs_bucket_created: postgres_timeline.ubid)).and_call_original

        postgres_timeline.create_bucket
      end
    end

    describe "#set_lifecycle_policy" do
      let(:storage_client) { instance_double(Google::Cloud::Storage::Project) }
      let(:bucket) { instance_double(Google::Cloud::Storage::Bucket) }
      let(:lifecycle) { instance_double(Google::Cloud::Storage::Bucket::Lifecycle) }

      before do
        expect(postgres_timeline).to receive(:blob_storage_client).and_return(storage_client)
        expect(storage_client).to receive(:bucket).with(postgres_timeline.ubid).and_return(bucket)
        expect(bucket).to receive(:lifecycle).and_yield(lifecycle)
      end

      it "sets delete lifecycle rule on the bucket" do
        expect(lifecycle).to receive(:add_delete_rule).with(age: PostgresTimeline::BACKUP_BUCKET_EXPIRATION_DAYS)
        postgres_timeline.set_lifecycle_policy
      end

      it "honors expiration_days: override" do
        expect(lifecycle).to receive(:add_delete_rule).with(age: 30)
        postgres_timeline.set_lifecycle_policy(expiration_days: 30)
      end
    end

    describe "#destroy_blob_storage" do
      it "deletes all files, bucket, and SA when access_key is set" do
        storage_client = instance_double(Google::Cloud::Storage::Project)
        iam_client = instance_double(Google::Apis::IamV1::IamService)
        bucket = instance_double(Google::Cloud::Storage::Bucket)
        expect(postgres_timeline).to receive(:blob_storage_client).and_return(storage_client)
        expect(storage_client).to receive(:bucket).with(postgres_timeline.ubid).and_return(bucket)

        file1 = instance_double(Google::Cloud::Storage::File)
        file2 = instance_double(Google::Cloud::Storage::File)
        expect(bucket).to receive(:files).and_return([file1, file2])
        expect(file1).to receive(:delete)
        expect(file2).to receive(:delete)
        expect(bucket).to receive(:delete)

        expect(postgres_timeline.location).to receive(:location_credential_gcp).and_return(location_credential_gcp)
        expect(location_credential_gcp).to receive(:iam_client).and_return(iam_client)
        expect(iam_client).to receive(:delete_project_service_account).with(
          "projects/-/serviceAccounts/#{postgres_timeline.access_key}",
        )

        postgres_timeline.destroy_blob_storage
      end

      it "handles missing bucket gracefully" do
        storage_client = instance_double(Google::Cloud::Storage::Project)
        iam_client = instance_double(Google::Apis::IamV1::IamService)
        expect(postgres_timeline).to receive(:blob_storage_client).and_return(storage_client)
        expect(storage_client).to receive(:bucket).with(postgres_timeline.ubid).and_return(nil)

        expect(postgres_timeline.location).to receive(:location_credential_gcp).and_return(location_credential_gcp)
        expect(location_credential_gcp).to receive(:iam_client).and_return(iam_client)
        expect(iam_client).to receive(:delete_project_service_account)

        postgres_timeline.destroy_blob_storage
      end

      it "handles already-deleted SA gracefully" do
        storage_client = instance_double(Google::Cloud::Storage::Project)
        iam_client = instance_double(Google::Apis::IamV1::IamService)
        expect(postgres_timeline).to receive(:blob_storage_client).and_return(storage_client)
        expect(storage_client).to receive(:bucket).with(postgres_timeline.ubid).and_return(nil)

        expect(postgres_timeline.location).to receive(:location_credential_gcp).and_return(location_credential_gcp)
        expect(location_credential_gcp).to receive(:iam_client).and_return(iam_client)
        expect(iam_client).to receive(:delete_project_service_account)
          .and_raise(Google::Apis::ClientError.new("Not Found", status_code: 404))

        postgres_timeline.destroy_blob_storage
      end

      it "handles missing SA reported as 403 gracefully" do
        storage_client = instance_double(Google::Cloud::Storage::Project)
        iam_client = instance_double(Google::Apis::IamV1::IamService)
        expect(postgres_timeline).to receive(:blob_storage_client).and_return(storage_client)
        expect(storage_client).to receive(:bucket).with(postgres_timeline.ubid).and_return(nil)

        expect(postgres_timeline.location).to receive(:location_credential_gcp).and_return(location_credential_gcp)
        expect(location_credential_gcp).to receive(:iam_client).and_return(iam_client)
        expect(iam_client).to receive(:delete_project_service_account)
          .and_raise(Google::Apis::ClientError.new("permission denied", status_code: 403))

        postgres_timeline.destroy_blob_storage
      end

      it "re-raises non-403/404 ClientError during SA delete" do
        storage_client = instance_double(Google::Cloud::Storage::Project)
        iam_client = instance_double(Google::Apis::IamV1::IamService)
        expect(postgres_timeline).to receive(:blob_storage_client).and_return(storage_client)
        expect(storage_client).to receive(:bucket).with(postgres_timeline.ubid).and_return(nil)

        expect(postgres_timeline.location).to receive(:location_credential_gcp).and_return(location_credential_gcp)
        expect(location_credential_gcp).to receive(:iam_client).and_return(iam_client)
        expect(iam_client).to receive(:delete_project_service_account)
          .and_raise(Google::Apis::ClientError.new("internal error", status_code: 500))

        expect { postgres_timeline.destroy_blob_storage }
          .to raise_error(Google::Apis::ClientError, /internal error/)
      end

      it "skips SA deletion when access_key is nil" do
        postgres_timeline.update(access_key: nil)
        storage_client = instance_double(Google::Cloud::Storage::Project)
        expect(postgres_timeline).to receive(:blob_storage_client).and_return(storage_client)
        expect(storage_client).to receive(:bucket).with(postgres_timeline.ubid).and_return(nil)

        expect(postgres_timeline.location).not_to receive(:location_credential_gcp)

        postgres_timeline.destroy_blob_storage
      end
    end

    describe "#setup_blob_storage" do
      it "is a no-op for GCP" do
        expect { postgres_timeline.setup_blob_storage }.not_to raise_error
      end
    end

    describe "#generate_blob_storage_credentials?" do
      it "returns false for GCP" do
        expect(postgres_timeline.generate_blob_storage_credentials?).to be false
      end
    end
  end
end
