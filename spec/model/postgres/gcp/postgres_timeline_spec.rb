# frozen_string_literal: true

require_relative "../../spec_helper"

RSpec.describe PostgresTimeline do
  subject(:postgres_timeline) {
    described_class.create(
      access_key: "test-sa@test-project.iam.gserviceaccount.com",
      secret_key: '{"type":"service_account"}',
      location_id: location.id
    )
  }

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

  before do
    location_credential
  end

  context "with GCP provider" do
    describe "#generate_walg_config" do
      it "returns GCS walg config" do
        walg_config = <<-WALG_CONF
WALG_GS_PREFIX=gs://#{postgres_timeline.ubid}
GOOGLE_APPLICATION_CREDENTIALS=/etc/postgresql/gcs-sa-key.json
PGHOST=/var/run/postgresql
PGDATA=/dat/17/data
        WALG_CONF

        expect(postgres_timeline.generate_walg_config(17)).to eq(walg_config)
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
        lcg = instance_double(LocationCredential, storage_client:)
        expect(postgres_timeline).to receive(:location).and_return(instance_double(Location, location_credential: lcg, name: "us-central1", provider_name: "gcp")).at_least(:once)
        expect(postgres_timeline.blob_storage_client).to eq(storage_client)
      end
    end

    describe "#list_objects" do
      it "returns wrapped GCS file objects with key and last_modified converted to Time" do
        bucket = instance_double(Google::Cloud::Storage::Bucket)
        storage_client = instance_double(Google::Cloud::Storage::Project)
        expect(postgres_timeline).to receive(:blob_storage_client).and_return(storage_client)

        updated_datetime = DateTime.now
        file1 = instance_double(Google::Cloud::Storage::File, name: "basebackups_005/0001_backup_stop_sentinel.json", updated_at: updated_datetime)
        file2 = instance_double(Google::Cloud::Storage::File, name: "basebackups_005/0002_data.tar", updated_at: updated_datetime)
        file_list = instance_double(Google::Cloud::Storage::File::List, to_a: [file1, file2], token: nil)

        expect(storage_client).to receive(:bucket).with(postgres_timeline.ubid).and_return(bucket)
        expect(bucket).to receive(:files).with(prefix: "basebackups_005/", delimiter: nil).and_return(file_list)

        objects = postgres_timeline.list_objects("basebackups_005/")
        expect(objects.length).to eq(2)
        expect(objects.first.key).to eq("basebackups_005/0001_backup_stop_sentinel.json")
        expect(objects.first.last_modified).to be_a(Time)
        expect(objects.first.last_modified).to eq(updated_datetime.to_time)
      end

      it "returns empty array when bucket does not exist" do
        storage_client = instance_double(Google::Cloud::Storage::Project)
        expect(postgres_timeline).to receive(:blob_storage_client).and_return(storage_client)
        expect(storage_client).to receive(:bucket).with(postgres_timeline.ubid).and_return(nil)

        expect(postgres_timeline.list_objects("prefix/")).to eq([])
      end

      it "handles pagination with delimiter" do
        bucket = instance_double(Google::Cloud::Storage::Bucket)
        storage_client = instance_double(Google::Cloud::Storage::Project)
        expect(postgres_timeline).to receive(:blob_storage_client).and_return(storage_client)

        file1 = instance_double(Google::Cloud::Storage::File, name: "file1", updated_at: Time.now)
        file2 = instance_double(Google::Cloud::Storage::File, name: "file2", updated_at: Time.now)
        page1 = instance_double(Google::Cloud::Storage::File::List, to_a: [file1], token: "next-page")
        page2 = instance_double(Google::Cloud::Storage::File::List, to_a: [file2], token: nil)

        expect(storage_client).to receive(:bucket).with(postgres_timeline.ubid).and_return(bucket)
        expect(bucket).to receive(:files).with(prefix: "prefix/", delimiter: "/").and_return(page1)
        expect(bucket).to receive(:files).with(prefix: "prefix/", delimiter: "/", token: "next-page").and_return(page2)

        objects = postgres_timeline.list_objects("prefix/", delimiter: "/")
        expect(objects.length).to eq(2)
        expect(objects.map(&:key)).to eq(["file1", "file2"])
      end

      it "handles pagination without delimiter" do
        bucket = instance_double(Google::Cloud::Storage::Bucket)
        storage_client = instance_double(Google::Cloud::Storage::Project)
        expect(postgres_timeline).to receive(:blob_storage_client).and_return(storage_client)

        file1 = instance_double(Google::Cloud::Storage::File, name: "file1", updated_at: Time.now)
        file2 = instance_double(Google::Cloud::Storage::File, name: "file2", updated_at: Time.now)
        page1 = instance_double(Google::Cloud::Storage::File::List, to_a: [file1], token: "next-page")
        page2 = instance_double(Google::Cloud::Storage::File::List, to_a: [file2], token: nil)

        expect(storage_client).to receive(:bucket).with(postgres_timeline.ubid).and_return(bucket)
        expect(bucket).to receive(:files).with(prefix: "prefix/", delimiter: nil).and_return(page1)
        expect(bucket).to receive(:files).with(prefix: "prefix/", delimiter: nil, token: "next-page").and_return(page2)

        objects = postgres_timeline.list_objects("prefix/")
        expect(objects.length).to eq(2)
        expect(objects.map(&:key)).to eq(["file1", "file2"])
      end
    end

    describe "#create_bucket" do
      it "creates a GCS bucket with uniform bucket level access" do
        storage_client = instance_double(Google::Cloud::Storage::Project)
        expect(postgres_timeline).to receive(:blob_storage_client).and_return(storage_client)

        expect(storage_client).to receive(:create_bucket).with(postgres_timeline.ubid, location: "us-central1").and_yield(
          instance_double(Google::Cloud::Storage::Bucket::Updater).tap do |b|
            expect(b).to receive(:uniform_bucket_level_access=).with(true)
          end
        )

        postgres_timeline.create_bucket
      end

      it "ignores AlreadyExistsError" do
        storage_client = instance_double(Google::Cloud::Storage::Project)
        expect(postgres_timeline).to receive(:blob_storage_client).and_return(storage_client)
        expect(storage_client).to receive(:create_bucket).and_raise(Google::Cloud::AlreadyExistsError.new("already exists"))

        expect { postgres_timeline.create_bucket }.not_to raise_error
      end
    end

    describe "#set_lifecycle_policy" do
      it "sets delete lifecycle rule on the bucket" do
        storage_client = instance_double(Google::Cloud::Storage::Project)
        bucket = instance_double(Google::Cloud::Storage::Bucket)
        expect(postgres_timeline).to receive(:blob_storage_client).and_return(storage_client)
        expect(storage_client).to receive(:bucket).with(postgres_timeline.ubid).and_return(bucket)

        expect(bucket).to receive(:lifecycle).and_yield(
          instance_double(Google::Cloud::Storage::Bucket::Lifecycle).tap do |l|
            expect(l).to receive(:add_delete_rule).with(age: PostgresTimeline::BACKUP_BUCKET_EXPIRATION_DAYS)
          end
        )

        postgres_timeline.set_lifecycle_policy
      end
    end
  end
end
