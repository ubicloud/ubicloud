# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe PostgresTimeline do
  subject(:postgres_timeline) { described_class.create(access_key: "dummy-access-key", secret_key: "dummy-secret-key", location_id: us_east_1.id) }

  let(:us_east_1) { Location.create(display_name: "us-east-1", name: "us-east-1", ui_name: "us-east-1", visible: true, provider: "aws") }

  it "returns ubid as bucket name" do
    expect(postgres_timeline.bucket_name).to eq(postgres_timeline.ubid)
  end

  it "returns walg config" do
    expect(postgres_timeline).to receive(:blob_storage).and_return(instance_double(described_class::S3BlobStorage, url: "https://blob-endpoint"))

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
      s3_client = Aws::S3::Client.new(stub_responses: true)
      s3_client.stub_responses(:list_objects_v2, {contents: [{key: "unrelated_file.txt"}, {key: "basebackups_005/0001_backup_stop_sentinel.json", last_modified: most_recent_backup_time - 200}, {key: "basebackups_005/0002_backup_stop_sentinel.json", last_modified: most_recent_backup_time - 100}, {key: "basebackups_005/0003_backup_stop_sentinel.json", last_modified: most_recent_backup_time}], is_truncated: false})
      expect(Aws::S3::Client).to receive(:new).and_return(s3_client)
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
    expect(Aws::S3::Client).to receive(:new).and_raise(RuntimeError.new("The AWS Access Key Id you provided does not exist in our records."))
    expect(postgres_timeline.backups).to eq([])
  end

  it "re-raises exceptions other than missin access key" do
    expect(Aws::S3::Client).to receive(:new).and_raise(RuntimeError.new("some error"))
    expect { postgres_timeline.backups }.to raise_error(RuntimeError)
  end

  it "returns list of backups for AWS regions" do
    s3_client = Aws::S3::Client.new(stub_responses: true)
    s3_client.stub_responses(:list_objects_v2, {contents: [{key: "backup_stop_sentinel.json"}, {key: "unrelated_file.txt"}], is_truncated: false})
    expect(s3_client).to receive(:list_objects_v2).with(bucket: postgres_timeline.ubid, prefix: "basebackups_005/").and_call_original
    expect(Aws::S3::Client).to receive(:new).and_return(s3_client)
    expect(postgres_timeline.backups.map(&:key)).to eq(["backup_stop_sentinel.json"])
  end

  it "returns list of backups with enumeration for AWS regions" do
    s3_client = Aws::S3::Client.new(stub_responses: true)
    s3_client.stub_responses(:list_objects_v2, {contents: [{key: "backup_stop_sentinel.json"}, {key: "unrelated_file.txt"}], is_truncated: true, next_continuation_token: "token"}, {contents: [{key: "backup_stop_sentinel.json"}, {key: "unrelated_file.txt"}], is_truncated: false})
    expect(s3_client).to receive(:list_objects_v2).with(bucket: postgres_timeline.ubid, prefix: "basebackups_005/").and_call_original
    expect(s3_client).to receive(:list_objects_v2).with(bucket: postgres_timeline.ubid, prefix: "basebackups_005/", continuation_token: "token").and_call_original
    expect(Aws::S3::Client).to receive(:new).and_return(s3_client)
    expect(postgres_timeline.backups.map(&:key)).to eq(["backup_stop_sentinel.json", "backup_stop_sentinel.json"])
  end

  it "returns blob storage endpoint" do
    expect(postgres_timeline.blob_storage_endpoint).to eq("https://s3.us-east-1.amazonaws.com")
  end

  it "returns blob storage client when aws properly" do
    expect(postgres_timeline.blob_storage_client).to be_a Aws::S3::Client
  end

  it "returns blob storage policy" do
    policy = {Version: "2012-10-17", Statement: [{Effect: "Allow", Action: ["s3:*"], Resource: ["arn:aws:s3:::dummy-ubid*"]}]}
    expect(postgres_timeline).to receive(:ubid).and_return("dummy-ubid")
    expect(postgres_timeline.blob_storage_policy).to eq(policy)
  end

  it "returns earliest restore time" do
    most_recent_backup_time = Date.today.to_time
    s3_client = Aws::S3::Client.new(stub_responses: true)
    s3_client.stub_responses(:list_objects_v2, {contents: [{key: "unrelated_file.txt"}, {key: "basebackups_005/0001_backup_stop_sentinel.json", last_modified: most_recent_backup_time - 200}, {key: "basebackups_005/0002_backup_stop_sentinel.json", last_modified: most_recent_backup_time - 100}, {key: "basebackups_005/0003_backup_stop_sentinel.json", last_modified: most_recent_backup_time}], is_truncated: false})
    expect(Aws::S3::Client).to receive(:new).and_return(s3_client)
    expect(postgres_timeline.earliest_restore_time).to eq(most_recent_backup_time - 200 + 300)
  end

  it "returns 5 minutes after cached earliest restore time" do
    expect(Aws::S3::Client).not_to receive(:new)
    most_recent_backup_time = Date.today.to_time.utc
    postgres_timeline.set(cached_earliest_backup_at: most_recent_backup_time)
    expect(postgres_timeline.earliest_restore_time).to eq(most_recent_backup_time + 300)
  end

  it "returns nil if all values are restore times are more than 8 days old" do
    s3_client = Aws::S3::Client.new(stub_responses: true)
    s3_client.stub_responses(:list_objects_v2, {contents: [], is_truncated: false})
    expect(Aws::S3::Client).to receive(:new).and_return(s3_client)
    expect(postgres_timeline.earliest_restore_time).to be_nil
  end

  describe "aws" do
    let(:s3_client) { Aws::S3::Client.new(stub_responses: true) }

    before do
      expect(Aws::S3::Client).to receive(:new).and_return(s3_client).at_least(:once)
    end

    it "creates bucket" do
      expect(postgres_timeline).to receive(:location).and_return(instance_double(Location, name: "us-east-2")).at_least(:once)
      s3_client.stub_responses(:create_bucket)
      expect(s3_client).to receive(:create_bucket).with({bucket: postgres_timeline.ubid, create_bucket_configuration: {location_constraint: "us-east-2"}}).and_return(true)
      expect(postgres_timeline.create_bucket).to be(true)
    end

    it "creates bucket in us-east-1" do
      expect(postgres_timeline).to receive(:location).and_return(instance_double(Location, name: "us-east-1")).at_least(:once)
      s3_client.stub_responses(:create_bucket)
      expect(s3_client).to receive(:create_bucket).with({bucket: postgres_timeline.ubid, create_bucket_configuration: nil}).and_return(true)
      expect(postgres_timeline.create_bucket).to be(true)
    end

    it "sets lifecycle policy" do
      s3_client.stub_responses(:put_bucket_lifecycle_configuration)
      expect(s3_client).to receive(:put_bucket_lifecycle_configuration).with({bucket: postgres_timeline.ubid, lifecycle_configuration: {rules: [{id: "DeleteOldBackups", status: "Enabled", expiration: {days: 8}, filter: {}}]}}).and_return(true)
      expect(postgres_timeline.set_lifecycle_policy).to be(true)
    end
  end
end
