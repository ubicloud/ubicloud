# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe PostgresTimeline do
  subject(:postgres_timeline) { described_class.create(access_key: "dummy-access-key", secret_key: "dummy-secret-key", location_id: location.id) }

  let(:project) { Project.create(name: "test-project") }
  let(:project_service) { Project.create(name: "test-service") }
  let(:location) { Location[Location::HETZNER_FSN1_ID] }
  let(:aws_location) {
    loc = Location.create(
      project_id: project.id, name: "us-east-2", display_name: "us-east-2",
      ui_name: "us-east-2", provider: "aws", visible: true
    )
    LocationCredential.create_with_id(loc, access_key: "access", secret_key: "secret")
    loc
  }
  let(:aws_timeline) { described_class.create(access_key: "key", secret_key: "secret", location_id: aws_location.id) }

  let(:minio_cluster) {
    DnsZone.create(project_id: project_service.id, name: "minio.test", last_purged_at: Time.new(2024, 1, 1, 0, 0, 0, "+00:00"))
    MinioCluster.create(
      project_id: project_service.id, location_id: location.id,
      name: "walg-minio", admin_user: "root", admin_password: "root",
      root_cert_1: "root_certs"
    )
  }

  before do
    allow(Config).to receive_messages(
      postgres_service_project_id: project_service.id,
      minio_service_project_id: project_service.id,
      minio_host_name: "minio.test"
    )
  end

  it "returns ubid as bucket name" do
    expect(postgres_timeline.bucket_name).to eq(postgres_timeline.ubid)
  end

  it "returns walg config" do
    minio_cluster

    walg_config = <<-WALG_CONF
WALG_S3_PREFIX=s3://#{postgres_timeline.ubid}
AWS_ENDPOINT=https://walg-minio.minio.test:9000
AWS_ACCESS_KEY_ID=dummy-access-key
AWS_SECRET_ACCESS_KEY=dummy-secret-key

AWS_REGION=us-east-1
AWS_S3_FORCE_PATH_STYLE=true
PGHOST=/var/run/postgresql
PGDATA=/dat/16/data
    WALG_CONF

    expect(postgres_timeline.generate_walg_config(16)).to eq(walg_config)
  end

  it "returns walg config for aws location" do
    walg_config = <<-WALG_CONF
WALG_S3_PREFIX=s3://#{aws_timeline.ubid}
AWS_ENDPOINT=https://s3.us-east-2.amazonaws.com
AWS_ACCESS_KEY_ID=key
AWS_SECRET_ACCESS_KEY=secret

AWS_REGION=us-east-2
AWS_S3_FORCE_PATH_STYLE=true
PGHOST=/var/run/postgresql
PGDATA=/dat/16/data
    WALG_CONF

    expect(aws_timeline.generate_walg_config(16)).to eq(walg_config)
  end

  it "returns walg config without keys when vm has iam_role" do
    minio_cluster
    postgres_timeline.update(access_key: nil, secret_key: nil)

    walg_config = <<-WALG_CONF
WALG_S3_PREFIX=s3://#{postgres_timeline.ubid}
AWS_ENDPOINT=https://walg-minio.minio.test:9000

AWS_REGION=us-east-1
AWS_S3_FORCE_PATH_STYLE=true
PGHOST=/var/run/postgresql
PGDATA=/dat/17/data
    WALG_CONF

    expect(postgres_timeline.generate_walg_config(17)).to eq(walg_config)
  end

  describe "#need_backup?" do
    let(:private_subnet) {
      PrivateSubnet.create(
        name: "test-ps", location_id: location.id, project_id: project.id,
        net6: NetAddr::IPv6Net.parse("fd10:9b0b:6b4b:8fbb::/64"),
        net4: NetAddr::IPv4Net.parse("10.0.0.0/26")
      )
    }
    let(:resource) {
      PostgresResource.create(
        project_id: project.id, location_id: location.id, name: "test-pg",
        target_version: "16", target_vm_size: "standard-2", target_storage_size_gib: 64,
        superuser_password: "super"
      )
    }
    let(:vm) { create_hosted_vm(project, private_subnet, "test-vm") }

    def create_leader
      server = PostgresServer.create(
        timeline: postgres_timeline, resource:, vm_id: vm.id,
        synchronization_status: "ready", timeline_access: "push", version: "16",
        representative_at: Time.new(2024, 1, 1, 0, 0, 0, "+00:00")
      )
      Strand.create_with_id(server, prog: "Postgres::PostgresServerNexus", label: "wait")
      server
    end

    it "returns false as backup needed if there is no backup endpoint is set" do
      create_leader
      expect(postgres_timeline.need_backup?).to be(false)
    end

    it "returns false as backup needed if there is no leader" do
      minio_cluster
      expect(postgres_timeline.need_backup?).to be(false)
    end

    it "returns true as backup needed if there is no backup process or the last backup failed" do
      minio_cluster
      create_leader
      expect(postgres_timeline.leader.vm.sshable).to receive(:_cmd).and_return("NotStarted", "Failed")
      expect(postgres_timeline.need_backup?).to be(true)
      expect(postgres_timeline.need_backup?).to be(true)
    end

    it "returns true as backup needed if previous backup started more than a day ago and is succeeded" do
      minio_cluster
      create_leader
      postgres_timeline.update(latest_backup_started_at: Time.new(2024, 1, 1, 0, 0, 0, "+00:00"))
      expect(postgres_timeline.leader.vm.sshable).to receive(:_cmd).and_return("Succeeded")
      expect(postgres_timeline.need_backup?).to be(true)
    end

    it "returns false as backup needed if previous backup started less than a day ago" do
      minio_cluster
      create_leader
      now = Time.new(2024, 6, 15, 12, 0, 0, "+00:00")
      expect(Time).to receive(:now).and_return(now).at_least(:once)
      postgres_timeline.update(latest_backup_started_at: now - 60 * 60 * 23)
      expect(postgres_timeline.leader.vm.sshable).to receive(:_cmd).and_return("Succeeded")
      expect(postgres_timeline.need_backup?).to be(false)
    end

    it "returns false as backup needed if previous backup started is in progress" do
      minio_cluster
      create_leader
      expect(postgres_timeline.leader.vm.sshable).to receive(:_cmd).and_return("InProgress")
      expect(postgres_timeline.need_backup?).to be(false)
    end
  end

  it "returns empty array if blob storage is not configured" do
    expect(postgres_timeline.backups).to eq([])
  end

  describe "with minio client" do
    let(:minio_client) { instance_double(Minio::Client) }

    before do
      minio_cluster
      expect(Minio::Client).to receive(:new).and_return(minio_client).at_least(:once)
    end

    describe "#latest_backup_label_before_target" do
      it "returns most recent backup before given target" do
        most_recent_backup_time = Time.new(2024, 1, 1, 0, 0, 0, "+00:00")
        expect(minio_client).to receive(:list_objects).and_return(
          [
            Minio::Client::Blob.new(postgres_timeline.ubid, "basebackups_005/0001_backup_stop_sentinel.json", last_modified: most_recent_backup_time - 200),
            Minio::Client::Blob.new(postgres_timeline.ubid, "basebackups_005/0002_backup_stop_sentinel.json", last_modified: most_recent_backup_time - 100),
            Minio::Client::Blob.new(postgres_timeline.ubid, "basebackups_005/0003_backup_stop_sentinel.json", last_modified: most_recent_backup_time)
          ]
        )

        expect(postgres_timeline.latest_backup_label_before_target(target: most_recent_backup_time - 50)).to eq("0002")
      end

      it "raises error if no backups before given target" do
        expect(minio_client).to receive(:list_objects).and_return([])

        expect { postgres_timeline.latest_backup_label_before_target(target: Time.new(2024, 1, 1, 0, 0, 0, "+00:00")) }.to raise_error RuntimeError, "BUG: no backup found"
      end
    end

    describe "#backups" do
      it "returns empty array if user is not created yet" do
        expect(minio_client).to receive(:list_objects).and_raise(RuntimeError.new("The AWS Access Key Id you provided does not exist in our records."))
        expect(postgres_timeline.backups).to eq([])
      end

      it "re-raises exceptions other than missing access key" do
        expect(minio_client).to receive(:list_objects).and_raise(RuntimeError.new("some error"))
        expect { postgres_timeline.backups }.to raise_error(RuntimeError)
      end

      it "returns list of backups" do
        expect(minio_client).to receive(:list_objects).with(postgres_timeline.ubid, "basebackups_005/", delimiter: "/").and_return([
          Minio::Client::Blob.new(postgres_timeline.ubid, "backup_stop_sentinel.json", last_modified: Time.new(2024, 1, 1, 0, 0, 0, "+00:00")),
          Minio::Client::Blob.new(postgres_timeline.ubid, "unrelated_file.txt", last_modified: Time.new(2024, 1, 1, 0, 0, 0, "+00:00"))
        ])

        expect(postgres_timeline.backups.map(&:key)).to eq(["backup_stop_sentinel.json"])
      end
    end

    it "returns earliest restore time" do
      backup_time = Time.now - 60 * 60 * 24 * 5
      expect(minio_client).to receive(:list_objects).and_return([
        Minio::Client::Blob.new(postgres_timeline.ubid, "backup_stop_sentinel.json", last_modified: backup_time)
      ])
      expect(postgres_timeline.earliest_restore_time.to_i).to be_within(5 * 60).of(backup_time.to_i + 5 * 60)
    end
  end

  it "returns list of backups for AWS regions" do
    s3_client = Aws::S3::Client.new(stub_responses: true)
    s3_client.stub_responses(:list_objects_v2, {contents: [{key: "backup_stop_sentinel.json"}, {key: "unrelated_file.txt"}], is_truncated: false})
    expect(s3_client).to receive(:list_objects_v2).with(bucket: aws_timeline.ubid, prefix: "basebackups_005/", delimiter: "/").and_call_original
    expect(Aws::S3::Client).to receive(:new).and_return(s3_client)
    expect(aws_timeline.backups.map(&:key)).to eq(["backup_stop_sentinel.json"])
  end

  it "returns list of backups with enumeration for AWS regions" do
    s3_client = Aws::S3::Client.new(stub_responses: true)
    s3_client.stub_responses(:list_objects_v2, {contents: [{key: "backup_stop_sentinel.json"}, {key: "unrelated_file.txt"}], is_truncated: true, next_continuation_token: "token"}, {contents: [{key: "backup_stop_sentinel.json"}, {key: "unrelated_file.txt"}], is_truncated: false})
    expect(s3_client).to receive(:list_objects_v2).with(bucket: aws_timeline.ubid, prefix: "basebackups_005/", delimiter: "/").and_call_original
    expect(s3_client).to receive(:list_objects_v2).with(bucket: aws_timeline.ubid, prefix: "basebackups_005/", delimiter: "/", continuation_token: "token").and_call_original
    expect(Aws::S3::Client).to receive(:new).and_return(s3_client)
    expect(aws_timeline.backups.map(&:key)).to eq(["backup_stop_sentinel.json", "backup_stop_sentinel.json"])
  end

  it "returns blob storage endpoint" do
    minio_cluster
    expect(postgres_timeline.blob_storage_endpoint).to eq("https://walg-minio.minio.test:9000")
  end

  it "works correctly with MinioCluster in Minio project" do
    minio_project = Project.create(name: "mc-project")
    expect(Config).to receive(:minio_service_project_id).and_return(minio_project.id).at_least(:once)
    mc = Prog::Minio::MinioClusterNexus.assemble(minio_project.id, "minio", Location::HETZNER_FSN1_ID, "minio-admin", 100, 1, 1, 1, "standard-2").subject

    expect(postgres_timeline.blob_storage.id).to eq(mc.id)
  end

  it "returns blob storage client from cache" do
    minio_cluster
    expect(Minio::Client).to receive(:new).and_return("dummy-client").once
    expect(postgres_timeline.blob_storage_client).to eq("dummy-client")
    expect(postgres_timeline.blob_storage_client).to eq("dummy-client")
  end

  it "returns blob storage policy" do
    policy = {Version: "2012-10-17", Statement: [{Effect: "Allow", Action: ["s3:*"], Resource: ["arn:aws:s3:::#{postgres_timeline.ubid}*"]}]}
    expect(postgres_timeline.blob_storage_policy).to eq(policy)
  end

  describe "#aws?" do
    it "returns false when location is nil" do
      postgres_timeline.update(location_id: nil)
      postgres_timeline.associations.delete(:location)
      expect(postgres_timeline.aws?).to be_nil
    end
  end

  describe "aws" do
    let(:s3_client) { Aws::S3::Client.new(stub_responses: true) }

    before do
      expect(Aws::S3::Client).to receive(:new).and_return(s3_client).at_least(:once)
    end

    it "creates bucket" do
      s3_client.stub_responses(:create_bucket)
      expect(s3_client).to receive(:create_bucket).with({bucket: aws_timeline.ubid, create_bucket_configuration: {location_constraint: "us-east-2"}}).and_call_original
      expect(aws_timeline.create_bucket).to be_truthy
    end

    it "creates bucket in us-east-1" do
      aws_location.update(name: "us-east-1")
      s3_client.stub_responses(:create_bucket)
      expect(s3_client).to receive(:create_bucket).with({bucket: aws_timeline.ubid, create_bucket_configuration: nil}).and_call_original
      expect(aws_timeline.create_bucket).to be_truthy
    end

    it "sets lifecycle policy" do
      s3_client.stub_responses(:put_bucket_lifecycle_configuration)
      expect(s3_client).to receive(:put_bucket_lifecycle_configuration).with({bucket: aws_timeline.ubid, lifecycle_configuration: {rules: [{id: "DeleteOldBackups", status: "Enabled", expiration: {days: 8}, filter: {}}]}}).and_call_original
      expect(aws_timeline.set_lifecycle_policy).to be_truthy
    end
  end

  describe "minio" do
    let(:minio_client) { instance_double(Minio::Client) }

    before do
      minio_cluster
      expect(Minio::Client).to receive(:new).and_return(minio_client).at_least(:once)
    end

    it "creates bucket" do
      expect(minio_client).to receive(:create_bucket).with(postgres_timeline.ubid).and_return(true)
      expect(postgres_timeline.create_bucket).to be(true)
    end

    it "sets lifecycle policy" do
      expect(minio_client).to receive(:set_lifecycle_policy).with(postgres_timeline.ubid, postgres_timeline.ubid, 8).and_return(true)
      expect(postgres_timeline.set_lifecycle_policy).to be(true)
    end
  end
end
