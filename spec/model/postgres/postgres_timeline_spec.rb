# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe PostgresTimeline do
  subject(:postgres_timeline) { described_class.create_with_id(access_key: "dummy-access-key", secret_key: "dummy-secret-key") }

  it "returns ubid as bucket name" do
    expect(postgres_timeline.bucket_name).to eq(postgres_timeline.ubid)
  end

  it "returns walg config" do
    expect(Project).to receive(:[]).and_return(instance_double(Project, minio_clusters: [instance_double(MinioCluster, connection_strings: ["https://blob-endpoint"])]))

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

    it "returns false as backup needed if there is recent backup status check" do
      expect(postgres_timeline).to receive(:last_ineffective_check_at).and_return(Time.now).twice
      expect(postgres_timeline.need_backup?).to be(false)
    end

    it "returns true as backup needed if there is no backup process or the last backup failed" do
      expect(postgres_timeline).to receive(:last_ineffective_check_at).and_return(Time.now - 60 * 60).exactly(4).times
      expect(sshable).to receive(:cmd).and_return("NotStarted")
      expect(postgres_timeline.need_backup?).to be(true)

      expect(sshable).to receive(:cmd).and_return("Failed")
      expect(postgres_timeline.need_backup?).to be(true)
    end

    it "returns true as backup needed if previous backup started more than a day ago and is succeeded" do
      expect(postgres_timeline).to receive(:last_ineffective_check_at).and_return(Time.now - 60 * 60).twice
      expect(postgres_timeline).to receive(:last_backup_started_at).and_return(Time.now - 60 * 60 * 25).twice
      expect(sshable).to receive(:cmd).and_return("Succeeded")
      expect(postgres_timeline.need_backup?).to be(true)
    end

    it "returns false as backup needed if previous backup started less than a day ago" do
      expect(postgres_timeline).to receive(:last_ineffective_check_at).and_return(Time.now - 60 * 60).twice
      expect(postgres_timeline).to receive(:last_backup_started_at).and_return(Time.now - 60 * 60 * 23).twice
      expect(sshable).to receive(:cmd).and_return("Succeeded")
      expect(postgres_timeline.need_backup?).to be(false)
    end

    it "returns false as backup needed if previous backup started is in progress" do
      expect(postgres_timeline).to receive(:last_ineffective_check_at).and_return(Time.now - 60 * 60).twice
      expect(sshable).to receive(:cmd).and_return("InProgress")
      expect(postgres_timeline.need_backup?).to be(false)
    end
  end

  it "returns blob storage client from cache" do
    expect(Project).to receive(:[]).and_return(instance_double(Project, minio_clusters: [instance_double(MinioCluster, connection_strings: ["https://blob-endpoint"])]))
    expect(MinioClient).to receive(:new).and_return("dummy-client").once
    expect(postgres_timeline.blob_storage_client).to eq("dummy-client")
    expect(postgres_timeline.blob_storage_client).to eq("dummy-client")
  end
end
