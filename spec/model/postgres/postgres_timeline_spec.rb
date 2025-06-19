# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe PostgresTimeline do
  subject(:postgres_timeline) { described_class.create_with_id(access_key: "dummy-access-key", secret_key: "dummy-secret-key", location_id: Location::HETZNER_FSN1_ID) }

  it "returns ubid as bucket name" do
    expect(postgres_timeline.bucket_name).to eq(postgres_timeline.ubid)
  end

  it "returns walg config" do
    expect(postgres_timeline).to receive(:blob_storage).and_return(instance_double(MinioCluster, url: "https://blob-endpoint"))

    walg_config = <<-WALG_CONF
WALG_S3_PREFIX=s3://#{postgres_timeline.ubid}
AWS_ENDPOINT=https://blob-endpoint
AWS_ACCESS_KEY_ID=dummy-access-key
AWS_SECRET_ACCESS_KEY=dummy-secret-key
AWS_REGION: us-east-1
AWS_S3_FORCE_PATH_STYLE=true
PGHOST=/var/run/postgresql
    WALG_CONF

    expect(postgres_timeline.generate_walg_config).to eq(walg_config)
  end

  describe "#need_backup?" do
    let(:sshable) { instance_double(Sshable) }
    let(:leader) {
      instance_double(
        PostgresServer,
        strand: instance_double(Strand, label: "wait"),
        vm: instance_double(Vm, sshable: sshable)
      )
    }

    before do
      allow(postgres_timeline).to receive(:leader).and_return(leader).at_least(:once)
    end

    it "returns false as backup needed if there is no backup endpoint is set" do
      expect(postgres_timeline).to receive(:blob_storage).and_return(nil)
      expect(postgres_timeline.need_backup?).to be(false)
    end

    it "returns false as backup needed if there is no leader" do
      expect(postgres_timeline).to receive(:blob_storage).and_return("dummy-blob-storage")
      expect(postgres_timeline).to receive(:leader).and_return(nil)
      expect(postgres_timeline.need_backup?).to be(false)
    end

    it "returns true as backup needed if there is no backup process or the last backup failed" do
      expect(postgres_timeline).to receive(:blob_storage).and_return("dummy-blob-storage").twice
      expect(sshable).to receive(:cmd).and_return("NotStarted", "Failed")
      expect(postgres_timeline.need_backup?).to be(true)
      expect(postgres_timeline.need_backup?).to be(true)
    end

    it "returns true as backup needed if previous backup started more than a day ago and is succeeded" do
      expect(postgres_timeline).to receive(:blob_storage).and_return("dummy-blob-storage")
      expect(postgres_timeline).to receive(:latest_backup_started_at).and_return(Time.now - 60 * 60 * 25).twice
      expect(sshable).to receive(:cmd).and_return("Succeeded")
      expect(postgres_timeline.need_backup?).to be(true)
    end

    it "returns false as backup needed if previous backup started less than a day ago" do
      expect(postgres_timeline).to receive(:blob_storage).and_return("dummy-blob-storage")
      expect(postgres_timeline).to receive(:latest_backup_started_at).and_return(Time.now - 60 * 60 * 23).twice
      expect(sshable).to receive(:cmd).and_return("Succeeded")
      expect(postgres_timeline.need_backup?).to be(false)
    end

    it "returns false as backup needed if previous backup started is in progress" do
      expect(postgres_timeline).to receive(:blob_storage).and_return("dummy-blob-storage")
      expect(sshable).to receive(:cmd).and_return("InProgress")
      expect(postgres_timeline.need_backup?).to be(false)
    end
  end

  describe "#latest_backup_label_before_target" do
    it "returns most recent backup before given target" do
      most_recent_backup_time = Time.now
      expect(postgres_timeline).to receive(:backups).and_return(
        [
          instance_double(Minio::Client::Blob, key: "basebackups_005/0001_backup_stop_sentinel.json", last_modified: most_recent_backup_time - 200),
          instance_double(Minio::Client::Blob, key: "basebackups_005/0002_backup_stop_sentinel.json", last_modified: most_recent_backup_time - 100),
          instance_double(Minio::Client::Blob, key: "basebackups_005/0003_backup_stop_sentinel.json", last_modified: most_recent_backup_time)
        ]
      )

      expect(postgres_timeline.latest_backup_label_before_target(target: most_recent_backup_time - 50)).to eq("0002")
    end

    it "raises error if no backups before given target" do
      expect(postgres_timeline).to receive(:backups).and_return([])

      expect { postgres_timeline.latest_backup_label_before_target(target: Time.now) }.to raise_error RuntimeError, "BUG: no backup found"
    end
  end

  it "returns empty array if blob storage is not configured" do
    expect(postgres_timeline).to receive(:blob_storage).and_return(nil)
    expect(postgres_timeline.backups).to eq([])
  end

  it "returns empty array if user is not created yet" do
    expect(postgres_timeline).to receive(:blob_storage).and_return(instance_double(MinioCluster, url: "https://blob-endpoint", root_certs: "certs")).at_least(:once)
    minio_client = instance_double(Minio::Client)
    expect(minio_client).to receive(:list_objects).and_raise(RuntimeError.new("The Access Key Id you provided does not exist in our records."))
    expect(Minio::Client).to receive(:new).and_return(minio_client)
    expect(postgres_timeline.backups).to eq([])
  end

  it "re-raises exceptions other than missin access key" do
    expect(postgres_timeline).to receive(:blob_storage).and_return(instance_double(MinioCluster, url: "https://blob-endpoint", root_certs: "certs")).at_least(:once)
    minio_client = instance_double(Minio::Client)
    expect(minio_client).to receive(:list_objects).and_raise(RuntimeError.new("some error"))
    expect(Minio::Client).to receive(:new).and_return(minio_client)
    expect { postgres_timeline.backups }.to raise_error(RuntimeError)
  end

  it "returns list of backups" do
    expect(postgres_timeline).to receive(:blob_storage).and_return(instance_double(MinioCluster, url: "https://blob-endpoint", root_certs: "certs")).at_least(:once)

    minio_client = Minio::Client.new(endpoint: "https://blob-endpoint", access_key: "access_key", secret_key: "secret_key", ssl_ca_data: "data")
    expect(minio_client).to receive(:list_objects).with(postgres_timeline.ubid, "basebackups_005/").and_return([instance_double(Minio::Client::Blob, key: "backup_stop_sentinel.json"), instance_double(Minio::Client::Blob, key: "unrelated_file.txt")])
    expect(Minio::Client).to receive(:new).and_return(minio_client)

    expect(postgres_timeline.backups.map(&:key)).to eq(["backup_stop_sentinel.json"])
  end

  it "returns list of backups for AWS regions" do
    expect(postgres_timeline).to receive(:location).and_return(instance_double(Location, aws?: true, name: "us-west-2")).at_least(:once)

    minio_client = Minio::Client.new(endpoint: "https://s3.us-west-2.amazonaws.com", access_key: "access_key", secret_key: "secret_key", ssl_ca_data: "data")
    expect(minio_client).to receive(:list_objects).with(postgres_timeline.ubid, "basebackups_005/").and_return([instance_double(Minio::Client::Blob, key: "backup_stop_sentinel.json"), instance_double(Minio::Client::Blob, key: "unrelated_file.txt")])
    expect(Minio::Client).to receive(:new).and_return(minio_client)

    expect(postgres_timeline.backups.map(&:key)).to eq(["backup_stop_sentinel.json"])
  end

  it "returns blob storage endpoint" do
    expect(MinioCluster).to receive(:[]).and_return(instance_double(MinioCluster, url: "https://blob-endpoint"))
    expect(postgres_timeline.blob_storage_endpoint).to eq("https://blob-endpoint")
  end

  it "returns blob storage client from cache" do
    expect(postgres_timeline).to receive(:blob_storage_endpoint).and_return("https://blob-endpoint")
    expect(postgres_timeline).to receive(:blob_storage).and_return(instance_double(MinioCluster, root_certs: "certs")).once
    expect(Minio::Client).to receive(:new).and_return("dummy-client").once
    expect(postgres_timeline.blob_storage_client).to eq("dummy-client")
    expect(postgres_timeline.blob_storage_client).to eq("dummy-client")
  end

  it "returns blob storage client when aws properly" do
    expect(postgres_timeline).to receive(:location).and_return(nil)
    expect(postgres_timeline).to receive(:blob_storage_endpoint).and_return("https://blob-endpoint")
    expect(postgres_timeline).to receive(:blob_storage).and_return(instance_double(MinioCluster, root_certs: "certs")).once
    expect(Minio::Client).to receive(:new).and_return("dummy-client").once
    expect(postgres_timeline.blob_storage_client).to eq("dummy-client")
  end

  it "returns blob storage policy" do
    policy = {Version: "2012-10-17", Statement: [{Effect: "Allow", Action: ["s3:*"], Resource: ["arn:aws:s3:::dummy-ubid*"]}]}
    expect(postgres_timeline).to receive(:ubid).and_return("dummy-ubid")
    expect(postgres_timeline.blob_storage_policy).to eq(policy)
  end

  it "returns earliest restore time" do
    expect(postgres_timeline).to receive(:backups).and_return([instance_double(Minio::Client::Blob, last_modified: Time.now - 60 * 60 * 24 * 5)])
    expect(postgres_timeline.earliest_restore_time.to_i).to be_within(5 * 60).of(Time.now.to_i - 60 * 60 * 24 * 5 + 5 * 60)
  end
end
