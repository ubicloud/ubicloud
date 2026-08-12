# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe PostgresTimeline do
  subject(:postgres_timeline) { described_class.create(access_key: "dummy-access-key", secret_key: "dummy-secret-key", location_id: Location::HETZNER_FSN1_ID) }

  def create_aws_location(name: "us-west-2")
    loc = Location.create(
      name:,
      display_name: "aws-#{name}",
      ui_name: "AWS #{name}",
      visible: true,
      provider: "aws",
    )
    LocationCredentialAws.create_with_id(loc, access_key: "aws-access-key", secret_key: "aws-secret-key")
    loc
  end

  def create_gcp_location
    Location.create(name: "us-central1", display_name: "gcp-us-central1", ui_name: "GCP US Central 1", visible: true, provider: "gcp")
  end

  def create_minio_cluster
    project = Project.create(name: "minio-service")
    allow(Config).to receive(:postgres_service_project_id).and_return(project.id)
    MinioCluster.create(project_id: project.id, location_id: postgres_timeline.location_id, name: "test-mc", admin_user: "admin", admin_password: "pw", root_cert_1: "ca-bundle")
  end

  it "returns ubid as bucket name" do
    expect(postgres_timeline.bucket_name).to eq(postgres_timeline.ubid)
  end

  it "returns walg config for metal" do
    expect(postgres_timeline).to receive(:blob_storage).and_return(instance_double(MinioCluster, url: "https://blob-endpoint"))

    walg_config = <<-WALG_CONF
WALG_S3_PREFIX=s3://#{postgres_timeline.ubid}
AWS_ENDPOINT=https://blob-endpoint
AWS_ACCESS_KEY_ID=dummy-access-key
AWS_SECRET_ACCESS_KEY=dummy-secret-key

AWS_REGION=us-east-1
AWS_S3_FORCE_PATH_STYLE=true
PGHOST=/var/run/postgresql
PGDATA=/dat/16/data
    WALG_CONF

    expect(postgres_timeline.generate_walg_config(16, instance_double(PostgresServer))).to eq(walg_config)
  end

  it "returns walg config for aws" do
    postgres_timeline.update(location_id: create_aws_location(name: "us-east-2").id)
    expect(postgres_timeline).to receive(:blob_storage).and_return(instance_double(MinioCluster, url: "https://blob-endpoint"))

    walg_config = <<-WALG_CONF
WALG_S3_PREFIX=s3://#{postgres_timeline.ubid}
AWS_ENDPOINT=https://blob-endpoint
AWS_ACCESS_KEY_ID=dummy-access-key
AWS_SECRET_ACCESS_KEY=dummy-secret-key

AWS_REGION=us-east-2
AWS_S3_FORCE_PATH_STYLE=true
PGHOST=/var/run/postgresql
PGDATA=/dat/16/data
    WALG_CONF

    expect(postgres_timeline.generate_walg_config(16, instance_double(PostgresServer))).to eq(walg_config)
  end

  it "returns walg config without keys when vm has iam_role for metal" do
    postgres_timeline.update(access_key: nil, secret_key: nil)
    expect(postgres_timeline).to receive(:blob_storage).and_return(instance_double(MinioCluster, url: "https://blob-endpoint"))

    walg_config = <<-WALG_CONF
WALG_S3_PREFIX=s3://#{postgres_timeline.ubid}
AWS_ENDPOINT=https://blob-endpoint

AWS_REGION=us-east-1
AWS_S3_FORCE_PATH_STYLE=true
PGHOST=/var/run/postgresql
PGDATA=/dat/17/data
    WALG_CONF

    expect(postgres_timeline.generate_walg_config(17, instance_double(PostgresServer))).to eq(walg_config)
  end

  it "returns walg config without keys when vm has iam_role for aws" do
    postgres_timeline.update(access_key: nil, secret_key: nil, location_id: create_aws_location(name: "us-east-2").id)
    expect(postgres_timeline).to receive(:blob_storage).and_return(instance_double(MinioCluster, url: "https://blob-endpoint"))

    walg_config = <<-WALG_CONF
WALG_S3_PREFIX=s3://#{postgres_timeline.ubid}
AWS_ENDPOINT=https://blob-endpoint

AWS_REGION=us-east-2
AWS_S3_FORCE_PATH_STYLE=true
PGHOST=/var/run/postgresql
PGDATA=/dat/17/data
    WALG_CONF

    expect(postgres_timeline.generate_walg_config(17, instance_double(PostgresServer))).to eq(walg_config)
  end

  it "appends hardware-sized wal-g config for aws when the feature is enabled (O_DIRECT on)" do
    postgres_timeline.update(location_id: create_aws_location(name: "us-east-2").id)
    expect(postgres_timeline).to receive(:blob_storage).and_return(instance_double(MinioCluster, url: "https://blob-endpoint"))
    allow(postgres_timeline).to receive(:leader).and_return(instance_double(PostgresServer,
      resource: instance_double(PostgresResource, project: instance_double(Project, get_ff_postgres_walg_optimized_config_disabled: false, get_ff_postgres_walg_direct_io_disabled: false))))
    server = instance_double(PostgresServer, vm: instance_double(Vm, vcpus: 48, memory_gib: 384),
      storage_device_paths: ["/dev/nvme1n1", "/dev/nvme2n1", "/dev/nvme3n1"],
      resource: instance_double(PostgresResource, target_vm_size: "i8ge.12xlarge"))

    config = postgres_timeline.generate_walg_config(17, server)
    expect(config).to include("WALG_UPLOAD_DISK_CONCURRENCY=48")   # i8ge dense NVMe -> vCPU under O_DIRECT
    expect(config).to include("WALG_S3_MAX_PART_SIZE=#{64 * 1024 * 1024}")
    expect(config).to include("WALG_DOWNLOAD_CONCURRENCY=48")
    expect(config).to include("WALG_DIRECT_IO=true")
    expect(config).to include("WALG_DIRECT_IO_BLOCK_COUNT=#{3 * 256}")   # drive count = RAID0 members (storage_device_paths)
  end

  it "uses buffered config (no O_DIRECT) when walg_config is on but direct_io is off" do
    postgres_timeline.update(location_id: create_aws_location(name: "us-east-2").id)
    expect(postgres_timeline).to receive(:blob_storage).and_return(instance_double(MinioCluster, url: "https://blob-endpoint"))
    allow(postgres_timeline).to receive(:leader).and_return(instance_double(PostgresServer,
      resource: instance_double(PostgresResource, project: instance_double(Project, get_ff_postgres_walg_optimized_config_disabled: nil, get_ff_postgres_walg_direct_io_disabled: true))))
    server = instance_double(PostgresServer, vm: instance_double(Vm, vcpus: 48, memory_gib: 384),
      resource: instance_double(PostgresResource, target_vm_size: "i8ge.12xlarge"))

    config = postgres_timeline.generate_walg_config(17, server)
    expect(config).to include("WALG_UPLOAD_DISK_CONCURRENCY=24")   # 1/2 vCPU (buffered; cpu.weight governs impact)
    expect(config).not_to include("WALG_DIRECT_IO")
  end

  it "omits wal-g config for aws when the feature is disabled (default no-op)" do
    postgres_timeline.update(location_id: create_aws_location(name: "us-east-2").id)
    expect(postgres_timeline).to receive(:blob_storage).and_return(instance_double(MinioCluster, url: "https://blob-endpoint"))
    allow(postgres_timeline).to receive(:leader).and_return(instance_double(PostgresServer,
      resource: instance_double(PostgresResource, project: instance_double(Project, get_ff_postgres_walg_optimized_config_disabled: true))))

    expect(postgres_timeline.generate_walg_config(17, instance_double(PostgresServer))).not_to include("WALG_UPLOAD_DISK_CONCURRENCY")
  end

  it "leaves stock config for aws when enabled but the server has no vm yet" do
    postgres_timeline.update(location_id: create_aws_location(name: "us-east-2").id)
    expect(postgres_timeline).to receive(:blob_storage).and_return(instance_double(MinioCluster, url: "https://blob-endpoint"))
    allow(postgres_timeline).to receive(:leader).and_return(instance_double(PostgresServer,
      resource: instance_double(PostgresResource, project: instance_double(Project, get_ff_postgres_walg_optimized_config_disabled: false))))

    expect(postgres_timeline.generate_walg_config(17, instance_double(PostgresServer, vm: nil))).not_to include("WALG_UPLOAD_DISK_CONCURRENCY")
  end

  it "leaves stock config when the timeline has no push-leader yet" do
    postgres_timeline.update(location_id: create_aws_location(name: "us-east-2").id)
    expect(postgres_timeline).to receive(:blob_storage).and_return(instance_double(MinioCluster, url: "https://blob-endpoint"))

    expect(postgres_timeline.generate_walg_config(17, instance_double(PostgresServer))).not_to include("WALG_UPLOAD_DISK_CONCURRENCY")
  end

  it "returns nil walg_config_params for metal (stock config, no hardware sizing)" do
    expect(postgres_timeline.walg_config_params(instance_double(PostgresServer))).to be_nil
  end

  it "returns walg_config_region for metal" do
    expect(postgres_timeline.walg_config_region).to eq("us-east-1")
  end

  it "returns walg_config_region for aws" do
    postgres_timeline.update(location_id: create_aws_location.id)
    expect(postgres_timeline.walg_config_region).to eq("us-west-2")
  end

  describe "#need_backup?" do
    let(:sshable) { Sshable.new }
    let(:leader) {
      instance_double(
        PostgresServer,
        strand: instance_double(Strand, label: "wait"),
        vm: instance_double(Vm, sshable:),
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

    it "returns true if no backup has been started yet" do
      expect(postgres_timeline).to receive(:blob_storage).and_return("dummy-blob-storage").twice
      expect(sshable).to receive(:_cmd).and_return("NotStarted", "Failed")
      expect(postgres_timeline.need_backup?).to be(true)
      expect(postgres_timeline.need_backup?).to be(true)
    end

    it "returns true if the previous backup is older than backup_period_hours" do
      expect(postgres_timeline).to receive(:blob_storage).and_return("dummy-blob-storage").twice
      expect(postgres_timeline).to receive(:latest_backup_started_at).and_return(Time.now - 60 * 60 * 25).exactly(4).times
      expect(sshable).to receive(:_cmd).and_return("NotStarted")
      expect(postgres_timeline.need_backup?).to be(true)
      postgres_timeline.update(backup_period_hours: 30)
      expect(postgres_timeline.need_backup?).to be(false)
    end

    it "returns false if the previous backup is within backup_period_hours" do
      expect(postgres_timeline).to receive(:blob_storage).and_return("dummy-blob-storage").twice
      expect(postgres_timeline).to receive(:latest_backup_started_at).and_return(Time.now - 60 * 60 * 23).exactly(4).times
      expect(sshable).to receive(:_cmd).and_return("NotStarted")
      expect(postgres_timeline.need_backup?).to be(false)
      postgres_timeline.update(backup_period_hours: 12)
      expect(postgres_timeline.need_backup?).to be(true)
    end

    it "returns false if a backup is currently in progress" do
      expect(postgres_timeline).to receive(:blob_storage).and_return("dummy-blob-storage")
      expect(sshable).to receive(:_cmd).and_return("InProgress")
      expect(postgres_timeline.need_backup?).to be(false)
    end

    it "returns true when take_backup_for_converge semaphore is set, even if last backup is recent" do
      expect(postgres_timeline).to receive(:blob_storage).and_return("dummy-blob-storage")
      postgres_timeline.update(latest_backup_started_at: Time.now)
      Strand.create_with_id(postgres_timeline, prog: "Postgres::PostgresTimelineNexus", label: "wait")
      postgres_timeline.incr_take_backup_for_converge
      expect(postgres_timeline.need_backup?).to be(true)
    end
  end

  it "#provider_dispatcher_group_name delegates to location" do
    expect(postgres_timeline.provider_dispatcher_group_name).to eq("metal")
  end

  describe "#any_archived_wal?" do
    def blob(key)
      instance_double(Minio::Client::Blob, key: "wal_005/#{key}")
    end

    it "returns false if blob storage is not configured" do
      expect(postgres_timeline).to receive(:blob_storage).and_return(nil)
      expect(described_class.any_archived_wal?(postgres_timeline)).to be false
    end

    context "with blob storage" do
      before do
        allow(postgres_timeline).to receive(:blob_storage).and_return(instance_double(MinioCluster))
      end

      it "returns false when no WAL segments archived" do
        expect(postgres_timeline).to receive(:list_objects).with("wal_005/").and_return([])
        expect(postgres_timeline.any_archived_wal?).to be false
      end

      it "returns true when a WAL segment is archived" do
        expect(postgres_timeline).to receive(:list_objects).with("wal_005/").and_return([blob("000000010000000200000003.lz4")])
        expect(postgres_timeline.any_archived_wal?).to be true
      end

      it "ignores non-segment keys like timeline history files" do
        expect(postgres_timeline).to receive(:list_objects).with("wal_005/").and_return([blob("00000002.history")])
        expect(postgres_timeline.any_archived_wal?).to be false
      end
    end
  end

  describe "#latest_backup_label_before_target" do
    it "returns most recent backup before given target" do
      most_recent_backup_time = Time.now
      expect(postgres_timeline).to receive(:backups).and_return(
        [
          instance_double(Minio::Client::Blob, key: "basebackups_005/0001_backup_stop_sentinel.json", last_modified: most_recent_backup_time - 200),
          instance_double(Minio::Client::Blob, key: "basebackups_005/0002_backup_stop_sentinel.json", last_modified: most_recent_backup_time - 100),
          instance_double(Minio::Client::Blob, key: "basebackups_005/0003_backup_stop_sentinel.json", last_modified: most_recent_backup_time),
        ],
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
    expect(minio_client).to receive(:list_objects).with(postgres_timeline.ubid, "basebackups_005/", delimiter: "/").and_return([instance_double(Minio::Client::Blob, key: "backup_stop_sentinel.json"), instance_double(Minio::Client::Blob, key: "unrelated_file.txt")])
    expect(Minio::Client).to receive(:new).and_return(minio_client)

    expect(postgres_timeline.backups.map(&:key)).to eq(["backup_stop_sentinel.json"])
  end

  it "returns list of backups for AWS regions" do
    postgres_timeline.update(location_id: create_aws_location.id)

    s3_client = Aws::S3::Client.new(stub_responses: true)
    s3_client.stub_responses(:list_objects_v2, {contents: [{key: "backup_stop_sentinel.json"}, {key: "unrelated_file.txt"}], is_truncated: false})
    expect(s3_client).to receive(:list_objects_v2).with(bucket: postgres_timeline.ubid, prefix: "basebackups_005/", delimiter: "/").and_call_original
    expect(Aws::S3::Client).to receive(:new).and_return(s3_client)
    expect(postgres_timeline.backups.map(&:key)).to eq(["backup_stop_sentinel.json"])
  end

  it "returns list of backups with enumeration for AWS regions" do
    postgres_timeline.update(location_id: create_aws_location.id)

    s3_client = Aws::S3::Client.new(stub_responses: true)
    s3_client.stub_responses(:list_objects_v2, {contents: [{key: "backup_stop_sentinel.json"}, {key: "unrelated_file.txt"}], is_truncated: true, next_continuation_token: "token"}, {contents: [{key: "backup_stop_sentinel.json"}, {key: "unrelated_file.txt"}], is_truncated: false})
    expect(s3_client).to receive(:list_objects_v2).with(bucket: postgres_timeline.ubid, prefix: "basebackups_005/", delimiter: "/").and_call_original
    expect(s3_client).to receive(:list_objects_v2).with(bucket: postgres_timeline.ubid, prefix: "basebackups_005/", delimiter: "/", continuation_token: "token").and_call_original
    expect(Aws::S3::Client).to receive(:new).and_return(s3_client)
    expect(postgres_timeline.backups.map(&:key)).to eq(["backup_stop_sentinel.json", "backup_stop_sentinel.json"])
  end

  it "returns blob storage endpoint" do
    expect(MinioCluster).to receive(:first).and_return(instance_double(MinioCluster, url: "https://blob-endpoint"))
    expect(postgres_timeline.blob_storage_endpoint).to eq("https://blob-endpoint")
  end

  it "works correctly with MinioCluster in Minio project" do
    minio_project = Project.create(name: "mc-project")
    pg_project = Project.create(name: "mc-project")
    expect(Config).to receive(:minio_service_project_id).and_return(minio_project.id).at_least(:once)
    expect(Config).to receive(:postgres_service_project_id).and_return(pg_project.id)
    mc = Prog::Minio::MinioClusterNexus.assemble(minio_project.id, "minio", Location::HETZNER_FSN1_ID, "minio-admin", 100, 1, 1, 1, "standard-2").subject

    expect(postgres_timeline.blob_storage.id).to eq(mc.id)
  end

  it "returns blob storage client from cache" do
    expect(postgres_timeline).to receive(:blob_storage_endpoint).and_return("https://blob-endpoint")
    expect(postgres_timeline).to receive(:blob_storage).and_return(instance_double(MinioCluster, root_certs: "certs")).once
    expect(Minio::Client).to receive(:new).and_return("dummy-client").once
    expect(postgres_timeline.blob_storage_client).to eq("dummy-client")
    expect(postgres_timeline.blob_storage_client).to eq("dummy-client")
  end

  it "returns blob storage client for metal" do
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

  it "returns read-only download blob storage policy" do
    ubid = postgres_timeline.ubid
    policy = {Version: "2012-10-17", Statement: [
      {Effect: "Allow", Action: ["s3:ListBucket", "s3:GetBucketLocation"], Resource: ["arn:aws:s3:::#{ubid}"]},
      {Effect: "Allow", Action: ["s3:GetObject", "s3:GetObjectVersion"], Resource: ["arn:aws:s3:::#{ubid}/basebackups_005/*", "arn:aws:s3:::#{ubid}/wal_005/*"]},
    ]}
    expect(postgres_timeline.download_blob_storage_policy).to eq(policy)
  end

  it "returns earliest restore time" do
    expect(postgres_timeline).to receive(:backups).and_return([instance_double(Minio::Client::Blob, last_modified: Time.now - 60 * 60 * 24 * 5)])
    expect(postgres_timeline.earliest_restore_time.to_i).to be_within(5 * 60).of(Time.now.to_i - 60 * 60 * 24 * 5 + 5 * 60)
  end

  describe "aws" do
    let(:s3_client) { Aws::S3::Client.new(stub_responses: true) }

    before do
      expect(postgres_timeline).to receive(:provider_dispatcher_group_name).and_return("aws").at_least(:once)
      expect(Aws::S3::Client).to receive(:new).and_return(s3_client).at_least(:once)
    end

    it "creates bucket" do
      expect(postgres_timeline).to receive(:location).and_return(instance_double(Location, aws?: true, provider_dispatcher_group_name: "aws", name: "us-east-2", location_credential_aws: instance_double(LocationCredentialAws, credentials: nil))).at_least(:once)
      s3_client.stub_responses(:create_bucket)
      expect(s3_client).to receive(:create_bucket).with({bucket: postgres_timeline.ubid, create_bucket_configuration: {tags: Util.aws_tags(postgres_timeline.ubid), location_constraint: "us-east-2"}})
      postgres_timeline.create_bucket
    end

    it "creates bucket in us-east-1" do
      expect(postgres_timeline).to receive(:location).and_return(instance_double(Location, aws?: true, provider_dispatcher_group_name: "aws", name: "us-east-1", location_credential_aws: instance_double(LocationCredentialAws, credentials: nil))).at_least(:once)
      s3_client.stub_responses(:create_bucket)
      expect(s3_client).to receive(:create_bucket).with({bucket: postgres_timeline.ubid, create_bucket_configuration: {tags: Util.aws_tags(postgres_timeline.ubid)}})
      postgres_timeline.create_bucket
    end

    describe "#set_lifecycle_policy" do
      def expected_lifecycle_config(days)
        {bucket: postgres_timeline.ubid, lifecycle_configuration: {rules: [{id: "DeleteOldBackups", status: "Enabled", expiration: {days:}, filter: {}}]}}
      end

      before do
        expect(postgres_timeline).to receive(:location).and_return(instance_double(Location, aws?: true, provider_dispatcher_group_name: "aws", name: "us-west-2", location_credential_aws: instance_double(LocationCredentialAws, credentials: nil))).at_least(:once)
        s3_client.stub_responses(:put_bucket_lifecycle_configuration)
      end

      it "defaults to BACKUP_BUCKET_EXPIRATION_DAYS" do
        expect(s3_client).to receive(:put_bucket_lifecycle_configuration).with(expected_lifecycle_config(PostgresTimeline::BACKUP_BUCKET_EXPIRATION_DAYS)).and_return(true)
        expect(postgres_timeline.set_lifecycle_policy).to be(true)
      end

      it "honors expiration_days: override" do
        expect(s3_client).to receive(:put_bucket_lifecycle_configuration).with(expected_lifecycle_config(30)).and_return(true)
        expect(postgres_timeline.set_lifecycle_policy(expiration_days: 30)).to be(true)
      end
    end

    describe "#destroy_blob_storage" do
      let(:iam_client) { Aws::IAM::Client.new(stub_responses: true) }
      let(:policy_arn) { "arn:aws:iam::123456789012:policy/#{postgres_timeline.ubid}" }

      before do
        postgres_timeline.update(location_id: create_aws_location.id)
        allow(Aws::IAM::Client).to receive(:new).and_return(iam_client)
        sts_client = Aws::STS::Client.new(stub_responses: true)
        sts_client.stub_responses(:get_caller_identity, account: "123456789012")
        allow(Aws::STS::Client).to receive(:new).and_return(sts_client)
        # A clean bucket and an unattached policy unless a test overrides them,
        # so each test states only the partial state it is about.
        s3_client.stub_responses(:list_objects_v2, {contents: []})
        s3_client.stub_responses(:delete_bucket)
        iam_client.stub_responses(:list_access_keys, access_key_metadata: [])
        iam_client.stub_responses(:list_attached_user_policies, attached_policies: [])
        iam_client.stub_responses(:list_entities_for_policy, policy_users: [], policy_roles: [], policy_groups: [])
      end

      it "empties the bucket, then tears down the user and its policy" do
        s3_client.stub_responses(:list_objects_v2, {contents: [{key: "basebackups_005/backup"}]}, {contents: []})
        iam_client.stub_responses(:list_access_keys, access_key_metadata: [{access_key_id: "AKIA"}])
        iam_client.stub_responses(:list_attached_user_policies, attached_policies: [{policy_arn:}])

        expect(s3_client).to receive(:delete_objects).with(bucket: postgres_timeline.ubid, delete: {objects: [{key: "basebackups_005/backup"}]})
        expect(s3_client).to receive(:delete_bucket).with(bucket: postgres_timeline.ubid)
        expect(iam_client).to receive(:delete_access_key).with(user_name: postgres_timeline.ubid, access_key_id: "AKIA")
        expect(iam_client).to receive(:detach_user_policy).with(user_name: postgres_timeline.ubid, policy_arn:)
        expect(iam_client).to receive(:delete_user).with(user_name: postgres_timeline.ubid)
        expect(iam_client).to receive(:delete_policy).with(policy_arn:)

        postgres_timeline.destroy_blob_storage
      end

      it "detaches the policy from its server role and deletes it (iam-access mode)" do
        # iam-access mode creates no user, and attaches the policy to a server
        # role instead; the unconditional user teardown no-ops on the absent
        # user while the policy is detached and deleted.
        gone = Aws::IAM::Errors::NoSuchEntity.new(nil, "NoSuchEntity")
        expect(iam_client).to receive(:list_access_keys).and_raise(gone)
        expect(iam_client).to receive(:list_attached_user_policies).and_raise(gone)
        expect(iam_client).to receive(:delete_user).and_raise(gone)
        iam_client.stub_responses(:list_entities_for_policy, policy_users: [], policy_roles: [{role_name: "server-role"}], policy_groups: [])

        expect(iam_client).to receive(:detach_role_policy).with(role_name: "server-role", policy_arn:)
        expect(iam_client).to receive(:delete_policy).with(policy_arn:)

        postgres_timeline.destroy_blob_storage
      end

      it "detaches every remaining user, role and group before deleting the policy" do
        iam_client.stub_responses(:list_entities_for_policy, policy_users: [{user_name: "u"}], policy_roles: [{role_name: "r"}], policy_groups: [{group_name: "g"}])

        expect(iam_client).to receive(:detach_user_policy).with(user_name: "u", policy_arn:)
        expect(iam_client).to receive(:detach_role_policy).with(role_name: "r", policy_arn:)
        expect(iam_client).to receive(:detach_group_policy).with(group_name: "g", policy_arn:)
        expect(iam_client).to receive(:delete_policy).with(policy_arn:)

        postgres_timeline.destroy_blob_storage
      end

      it "completes the policy teardown when the user is already gone" do
        gone = Aws::IAM::Errors::NoSuchEntity.new(nil, "NoSuchEntity")
        expect(iam_client).to receive(:list_access_keys).and_raise(gone)
        expect(iam_client).to receive(:list_attached_user_policies).and_raise(gone)
        expect(iam_client).to receive(:delete_user).and_raise(gone)

        expect(iam_client).to receive(:delete_policy).with(policy_arn:)

        postgres_timeline.destroy_blob_storage
      end

      it "tolerates a policy that is already gone" do
        gone = Aws::IAM::Errors::NoSuchEntity.new(nil, "NoSuchEntity")
        expect(iam_client).to receive(:list_entities_for_policy).and_raise(gone)
        expect(iam_client).to receive(:delete_policy).and_raise(gone)

        postgres_timeline.destroy_blob_storage
      end

      it "treats a missing bucket as already deleted" do
        s3_client.stub_responses(:list_objects_v2, "NoSuchBucket")

        expect(iam_client).to receive(:delete_policy).with(policy_arn:)

        postgres_timeline.destroy_blob_storage
      end

      it "re-empties and retries a bucket that briefly reports BucketNotEmpty" do
        s3_client.stub_responses(:delete_bucket, "BucketNotEmpty", {})

        expect(s3_client).to receive(:delete_bucket).twice.and_call_original
        expect(iam_client).to receive(:delete_policy).with(policy_arn:)

        postgres_timeline.destroy_blob_storage
      end

      it "gives up on a bucket that never empties, after a bounded number of tries" do
        s3_client.stub_responses(:delete_bucket, "BucketNotEmpty")

        expect(s3_client).to receive(:delete_bucket).exactly(PostgresTimeline::Aws::AWS_BUCKET_DELETE_ATTEMPTS).times.and_call_original

        expect { postgres_timeline.destroy_blob_storage }.to raise_error(Aws::S3::Errors::BucketNotEmpty)
      end

      it "deletes only the bucket and the policy when the IAM sweep is disabled" do
        # A deployment that has only ever run in iam-access mode has no user,
        # no access key and no surviving role attachment, so it can drop the
        # IAM permissions the sweep needs.
        expect(Config).to receive(:aws_postgres_blob_storage_iam_sweep).and_return(false)

        expect(s3_client).to receive(:delete_bucket).with(bucket: postgres_timeline.ubid)
        expect(iam_client).not_to receive(:list_access_keys)
        expect(iam_client).not_to receive(:list_attached_user_policies)
        expect(iam_client).not_to receive(:delete_user)
        expect(iam_client).not_to receive(:list_entities_for_policy)
        expect(iam_client).to receive(:delete_policy).with(policy_arn:)

        postgres_timeline.destroy_blob_storage
      end
    end
  end

  describe "minio" do
    let(:minio_client) { instance_double(Minio::Client) }

    before do
      expect(postgres_timeline).to receive(:provider_dispatcher_group_name).and_return("metal").at_least(:once)
      expect(postgres_timeline).to receive(:blob_storage).and_return(instance_double(MinioCluster, url: "https://blob-endpoint", root_certs: "certs")).at_least(:once)
      expect(Minio::Client).to receive(:new).and_return(minio_client).at_least(:once)
    end

    it "creates bucket" do
      expect(minio_client).to receive(:create_bucket).with(postgres_timeline.ubid).and_return(true)
      expect(postgres_timeline.create_bucket).to be(true)
    end

    it "swallows BucketAlreadyOwnedByYou errors on bucket creation" do
      expect(minio_client).to receive(:create_bucket).with(postgres_timeline.ubid).and_raise(RuntimeError.new("Error: <Code>BucketAlreadyOwnedByYou</Code>"))
      expect { postgres_timeline.create_bucket }.not_to raise_error
    end

    it "re-raises other RuntimeErrors on bucket creation" do
      expect(minio_client).to receive(:create_bucket).with(postgres_timeline.ubid).and_raise(RuntimeError.new("Error: something else"))
      expect { postgres_timeline.create_bucket }.to raise_error(RuntimeError, /something else/)
    end

    describe "#set_lifecycle_policy" do
      it "defaults to BACKUP_BUCKET_EXPIRATION_DAYS" do
        expect(minio_client).to receive(:set_lifecycle_policy).with(postgres_timeline.ubid, postgres_timeline.ubid, PostgresTimeline::BACKUP_BUCKET_EXPIRATION_DAYS).and_return(true)
        expect(postgres_timeline.set_lifecycle_policy).to be(true)
      end

      it "honors expiration_days: override" do
        expect(minio_client).to receive(:set_lifecycle_policy).with(postgres_timeline.ubid, postgres_timeline.ubid, 30).and_return(true)
        expect(postgres_timeline.set_lifecycle_policy(expiration_days: 30)).to be(true)
      end
    end
  end

  describe "#create_download_credentials" do
    context "when aws" do
      before do
        postgres_timeline.update(location_id: create_aws_location(name: "us-east-2").id)
      end

      it "federates a session down from the timeline's own writer credential" do
        sts_client = Aws::STS::Client.new(stub_responses: true)
        expect(Aws::STS::Client).to receive(:new) do |region:, credentials:|
          expect(region).to eq("us-east-2")
          expect(credentials.access_key_id).to eq("dummy-access-key")
          expect(credentials.secret_access_key).to eq("dummy-secret-key")
          sts_client
        end
        expiration = Time.at((Time.now + 36 * 60 * 60).to_i)
        sts_client.stub_responses(:get_federation_token, credentials: {access_key_id: "AKID", secret_access_key: "SECRET", session_token: "TOKEN", expiration:})
        expect(sts_client).to receive(:get_federation_token).with(hash_including(name: postgres_timeline.ubid, duration_seconds: PostgresTimeline::DOWNLOAD_CREDENTIALS_DURATION_SECONDS)).and_call_original

        result = postgres_timeline.create_download_credentials
        expect(result).to eq({access_key_id: "AKID", secret_access_key: "SECRET", session_token: "TOKEN", expiration:})
      end

      it "raises when the timeline has no static writer credential to federate from" do
        postgres_timeline.update(access_key: nil, secret_key: nil)
        expect { postgres_timeline.create_download_credentials }.to raise_error(RuntimeError, "Backup download credentials require per-timeline blob storage credentials, which are not configured for this resource")
      end
    end

    context "when metal" do
      it "assumes role from its own bucket-scoped blob storage client" do
        create_minio_cluster
        expiration = Time.now + 36 * 60 * 60
        minio_client = instance_double(Minio::Client)
        expect(Minio::Client).to receive(:new).and_return(minio_client)
        expect(minio_client).to receive(:assume_role).with(policy: postgres_timeline.download_blob_storage_policy, duration_seconds: PostgresTimeline::DOWNLOAD_CREDENTIALS_DURATION_SECONDS)
          .and_return({access_key_id: "AKID", secret_access_key: "SECRET", session_token: "TOKEN", expiration:})

        result = postgres_timeline.create_download_credentials
        expect(result).to eq({access_key_id: "AKID", secret_access_key: "SECRET", session_token: "TOKEN", expiration:})
      end
    end

    context "when gcp" do
      it "raises, since backup downloads are not supported for gcp" do
        postgres_timeline.update(location_id: create_gcp_location.id)
        expect { postgres_timeline.create_download_credentials }.to raise_error(RuntimeError, "Backup download credentials are not supported for GCP-hosted PostgreSQL resources")
      end
    end
  end

  describe "#refresh_blob_storage_policy" do
    context "when aws" do
      let(:iam_client) { Aws::IAM::Client.new(stub_responses: true) }

      before do
        postgres_timeline.update(location_id: create_aws_location(name: "us-east-2").id)
        credential = postgres_timeline.location.location_credential_aws
        allow(credential).to receive_messages(iam_client:, aws_iam_account_id: "123456789012")
      end

      it "sets a new default policy version from the current policy document" do
        iam_client.stub_responses(:list_policy_versions, versions: [{version_id: "v1", is_default_version: true}])
        expect(iam_client).not_to receive(:delete_policy_version)
        expect(iam_client).to receive(:create_policy_version) do |args|
          expect(args[:policy_arn]).to eq(postgres_timeline.aws_s3_policy_arn)
          expect(args[:set_as_default]).to be(true)
          actions = JSON.parse(args[:policy_document])["Statement"].map { it["Action"] }
          expect(actions).to include(["sts:GetFederationToken"])
        end

        postgres_timeline.refresh_blob_storage_policy
      end

      it "drops the oldest non-default version when the 5-version limit is reached" do
        now = Time.now
        iam_client.stub_responses(:list_policy_versions, versions: [
          {version_id: "v1", is_default_version: false, create_date: now - 500},
          {version_id: "v2", is_default_version: false, create_date: now - 400},
          {version_id: "v3", is_default_version: false, create_date: now - 300},
          {version_id: "v4", is_default_version: false, create_date: now - 200},
          {version_id: "v5", is_default_version: true, create_date: now - 100},
        ])
        expect(iam_client).to receive(:delete_policy_version).with(policy_arn: postgres_timeline.aws_s3_policy_arn, version_id: "v1")
        expect(iam_client).to receive(:create_policy_version).with(hash_including(set_as_default: true))

        postgres_timeline.refresh_blob_storage_policy
      end

      it "prunes against a fresh listing and retries once when a stale count lets the create hit the limit" do
        now = Time.now
        five = [
          {version_id: "v1", is_default_version: false, create_date: now - 500},
          {version_id: "v2", is_default_version: false, create_date: now - 400},
          {version_id: "v3", is_default_version: false, create_date: now - 300},
          {version_id: "v4", is_default_version: false, create_date: now - 200},
          {version_id: "v5", is_default_version: true, create_date: now - 100},
        ]
        # First listing undercounts (skips the prune), so the create trips the cap; the
        # re-read then shows all five and the retry prunes before succeeding.
        iam_client.stub_responses(:list_policy_versions, {versions: [{version_id: "v5", is_default_version: true}]}, {versions: five})
        iam_client.stub_responses(:create_policy_version, "LimitExceeded", {})

        expect(iam_client).to receive(:delete_policy_version).with(policy_arn: postgres_timeline.aws_s3_policy_arn, version_id: "v1")
        expect(iam_client).to receive(:create_policy_version).twice.and_call_original

        postgres_timeline.refresh_blob_storage_policy
      end

      it "gives up after one retry when the limit is exceeded persistently" do
        now = Time.now
        five = [
          {version_id: "v1", is_default_version: false, create_date: now - 500},
          {version_id: "v2", is_default_version: false, create_date: now - 400},
          {version_id: "v3", is_default_version: false, create_date: now - 300},
          {version_id: "v4", is_default_version: false, create_date: now - 200},
          {version_id: "v5", is_default_version: true, create_date: now - 100},
        ]
        iam_client.stub_responses(:list_policy_versions, {versions: five}, {versions: five})
        iam_client.stub_responses(:create_policy_version, "LimitExceeded")
        allow(iam_client).to receive(:delete_policy_version)

        expect(iam_client).to receive(:create_policy_version).twice.and_call_original
        expect { postgres_timeline.refresh_blob_storage_policy }.to raise_error(Aws::IAM::Errors::LimitExceeded)
      end
    end

    it "does nothing for aws timelines using instance-profile credentials" do
      postgres_timeline.update(location_id: create_aws_location(name: "us-east-2").id)
      expect(Config).to receive(:aws_postgres_iam_access).and_return(true)
      expect(Aws::IAM::Client).not_to receive(:new)

      expect(postgres_timeline.refresh_blob_storage_policy).to be_nil
    end

    it "is a no-op for gcp timelines" do
      postgres_timeline.update(location_id: create_gcp_location.id)
      expect(postgres_timeline.refresh_blob_storage_policy).to be_nil
    end

    it "is a no-op for metal timelines" do
      expect(postgres_timeline.refresh_blob_storage_policy).to be_nil
    end
  end
end
