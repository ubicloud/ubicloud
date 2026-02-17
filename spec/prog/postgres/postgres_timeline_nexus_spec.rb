# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe Prog::Postgres::PostgresTimelineNexus do
  subject(:nx) { described_class.new(st) }

  let(:project) { Project.create(name: "test-project") }
  let(:postgres_timeline) { create_postgres_timeline(location_id:) }
  let(:st) { postgres_timeline.strand }
  let(:service_project) { Project.create(name: "postgres-service-project") }
  let(:location_id) { Location::HETZNER_FSN1_ID }

  let(:private_subnet) { create_private_subnet }

  def create_minio_cluster(location_id: self.location_id, project_id: service_project.id)
    mc = MinioCluster.create(
      location_id:,
      project_id:,
      name: "minio-cluster-test",
      admin_user: "admin",
      admin_password: "secret",
      root_cert_1: "certs",
      private_subnet_id: private_subnet.id
    )
    Strand.create_with_id(mc, prog: "Minio::MinioClusterNexus", label: "wait")
    mc
  end

  def create_postgres_server(resource:, timeline:, timeline_access: "push", is_representative: true, version: "16", strand_label: "wait", vm: nil, location_id: self.location_id, subnet: private_subnet)
    vm ||= Prog::Vm::Nexus.assemble_with_sshable(
      project.id, name: "pg-vm-test", private_subnet_id: subnet.id,
      location_id:, unix_user: "ubi"
    ).subject
    VmStorageVolume.create(vm:, boot: false, size_gib: 64, disk_index: 1)
    server = PostgresServer.create(
      timeline:,
      resource:,
      vm_id: vm.id,
      is_representative:,
      synchronization_status: "ready",
      timeline_access:,
      version:
    )
    Strand.create_with_id(server, prog: "Postgres::PostgresServerNexus", label: strand_label)
    server
  end

  def create_private_subnet(
    name: "pg-subnet",
    location_id: self.location_id,
    net4: "172.0.0.0/26",
    net6: "fdfa:b5aa:14a3:4a3d::/64"
  )
    PrivateSubnet.create(name:, project:, location_id:, net4:, net6:)
  end

  def create_aws_location
    loc = Location.create(
      name: "us-west-2",
      display_name: "AWS US West 2",
      ui_name: "aws-us-west-2",
      visible: true,
      provider: "aws"
    )
    LocationCredential.create_with_id(loc,
      access_key: "access-key-id",
      secret_key: "secret-access-key")
    loc
  end

  def backup_fixture(days_ago:)
    Struct.new(:key, :last_modified).new(
      "basebackups_005/base_backup_stop_sentinel.json",
      Time.now - days_ago * 24 * 60 * 60
    )
  end

  def mock_minio_client(methods = {})
    client = instance_double(Minio::Client, methods)
    expect(Minio::Client).to receive(:new).and_return(client)
    client
  end

  def mock_admin_minio_client(minio_cluster)
    client = instance_double(Minio::Client)
    expect(Minio::Client).to receive(:new).with(
      endpoint: minio_cluster.ip4_urls.first,
      access_key: minio_cluster.admin_user,
      secret_key: minio_cluster.admin_password,
      ssl_ca_data: minio_cluster.root_cert_1
    ).and_return(client)
    client
  end

  before do
    allow(Config).to receive(:postgres_service_project_id).and_return(service_project.id)
  end

  describe ".assemble" do
    it "throws an exception if parent is not found" do
      expect {
        described_class.assemble(location_id: Location::HETZNER_FSN1_ID, parent_id: PostgresResource.generate_uuid)
      }.to raise_error RuntimeError, "No existing parent"
    end

    it "throws an exception if location is not found" do
      expect {
        described_class.assemble(location_id: nil)
      }.to raise_error RuntimeError, "No existing location"
    end

    it "creates postgres timeline" do
      st = described_class.assemble(location_id: Location::HETZNER_FSN1_ID)

      expect(st.subject).to exist
    end

    it "does not generate access_key/secret_key when AWS & Config.aws_postgres_iam_access" do
      expect(Config).to receive(:aws_postgres_iam_access).and_return(true).twice

      tl = described_class.assemble(location_id: Location::HETZNER_FSN1_ID).subject
      expect(tl.access_key).not_to be_nil
      expect(tl.secret_key).not_to be_nil

      location = Location.create(name: "l1", display_name: "l1", ui_name: "l1", visible: true, provider: "aws")
      tl = described_class.assemble(location_id: location.id).subject
      expect(tl.access_key).to be_nil
      expect(tl.secret_key).to be_nil
    end
  end

  describe "#start" do
    describe "when blob storage is minio" do
      it "creates user and policies and hops" do
        minio_cluster = create_minio_cluster
        admin_client = mock_admin_minio_client(minio_cluster)

        expect(admin_client).to receive(:admin_add_user).with(postgres_timeline.access_key, postgres_timeline.secret_key).and_return(200)
        expect(admin_client).to receive(:admin_policy_add).with(postgres_timeline.ubid, postgres_timeline.blob_storage_policy).and_return(200)
        expect(admin_client).to receive(:admin_policy_set).with(postgres_timeline.ubid, postgres_timeline.access_key).and_return(200)
        expect { nx.start }.to hop("setup_bucket")
      end
    end

    describe "when blob storage is aws s3" do
      it "creates user and policies and hops" do
        aws_location = create_aws_location
        postgres_timeline.update(location_id: aws_location.id)
        resource = create_postgres_resource(project:, location_id: aws_location.id)
        aws_private_subnet = create_private_subnet(
          name: "aws-pg-subnet",
          location_id: aws_location.id,
          net4: "172.0.1.0/26",
          net6: "fdfa:b5aa:14a3:4a3e::/64"
        )
        server = create_postgres_server(resource:, timeline: postgres_timeline, location_id: aws_location.id, subnet: aws_private_subnet)
        server.strand.update(label: "wait")

        iam_client = Aws::IAM::Client.new(stub_responses: true)
        iam_client.stub_responses(:create_user)
        iam_client.stub_responses(:create_policy)
        iam_client.stub_responses(:attach_user_policy)
        iam_client.stub_responses(:create_access_key, access_key: {access_key_id: "access-key", secret_access_key: "secret-key", user_name: "username", status: "Active"})

        expect(nx.postgres_timeline.location.location_credential).to receive(:iam_client).and_return(iam_client).at_least(:once)

        expect { nx.start }.to hop("setup_bucket")

        postgres_timeline.reload
        expect(postgres_timeline.access_key).to eq("access-key")
        expect(postgres_timeline.secret_key).to eq("secret-key")
      end
    end

    it "hops without creating bucket if blob storage is not configured" do
      # No minio cluster created, so blob_storage is nil
      expect(nx).not_to receive(:setup_blob_storage)
      expect { nx.start }.to hop("wait_leader")
    end
  end

  describe "#setup_bucket" do
    it "hops to wait_leader if bucket is created" do
      create_minio_cluster
      blob_storage_client = mock_minio_client
      expect(blob_storage_client).to receive(:create_bucket)
      expect(blob_storage_client).to receive(:set_lifecycle_policy)
      expect { nx.setup_bucket }.to hop("wait_leader")
    end

    it "attach policy to role when vm has iam_role" do
      expect(Config).to receive(:aws_postgres_iam_access).and_return(true)
      aws_location = create_aws_location
      postgres_timeline.update(location_id: aws_location.id)

      iam_client = Aws::IAM::Client.new(stub_responses: true)
      iam_client.stub_responses(:create_policy, {policy: {arn: "policy-arn"}})
      expect(nx.postgres_timeline.location.location_credential).to receive(:iam_client).and_return(iam_client).at_least(:once)

      nx.setup_aws_s3
    end

    it "#destroy_aws_s3 detach policy to vm role when aws_postgres_iam_access configured" do
      expect(Config).to receive(:aws_postgres_iam_access).and_return(true)
      aws_location = create_aws_location
      postgres_timeline.update(location_id: aws_location.id)

      iam_client = Aws::IAM::Client.new(stub_responses: true)
      expect(nx.postgres_timeline.location.location_credential).to receive(:iam_client).and_return(iam_client).at_least(:once)
      expect(nx.postgres_timeline.location.location_credential).to receive(:aws_iam_account_id).and_return("123456789012")

      expect(iam_client).to receive(:delete_policy).with(policy_arn: "arn:aws:iam::123456789012:policy/#{postgres_timeline.ubid}")

      nx.destroy_aws_s3
    end

    it "naps if aws and the key is not available" do
      aws_location = create_aws_location
      postgres_timeline.update(location_id: aws_location.id, access_key: "not-access-key")

      iam_client = Aws::IAM::Client.new(stub_responses: true)
      iam_client.stub_responses(:list_access_keys, access_key_metadata: [{access_key_id: "access-key"}])
      expect(nx.postgres_timeline.location.location_credential).to receive(:iam_client).and_return(iam_client).at_least(:once)

      expect { nx.setup_bucket }.to nap(1)
    end

    it "hops to wait_leader if aws and the key is available" do
      aws_location = create_aws_location
      postgres_timeline.update(location_id: aws_location.id)

      iam_client = Aws::IAM::Client.new(stub_responses: true)
      iam_client.stub_responses(:list_access_keys, access_key_metadata: [{access_key_id: "dummy-access-key"}])
      expect(nx.postgres_timeline.location.location_credential).to receive(:iam_client).and_return(iam_client).at_least(:once)

      s3_client = Aws::S3::Client.new(stub_responses: true)
      s3_client.stub_responses(:create_bucket)
      s3_client.stub_responses(:put_bucket_lifecycle_configuration)
      expect(nx.postgres_timeline).to receive(:blob_storage_client).and_return(s3_client).at_least(:once)

      expect { nx.setup_bucket }.to hop("wait_leader")
    end
  end

  describe "#wait_leader" do
    it "naps if leader not ready" do
      create_minio_cluster
      resource = create_postgres_resource(project:, location_id:)
      create_postgres_server(resource:, timeline: postgres_timeline, strand_label: "start")

      expect { nx.wait_leader }.to nap(5)
    end

    it "hops if leader is ready" do
      create_minio_cluster
      resource = create_postgres_resource(project:, location_id:)
      create_postgres_server(resource:, timeline: postgres_timeline, strand_label: "wait")

      expect { nx.wait_leader }.to hop("wait")
    end
  end

  describe "#wait" do
    it "naps if blob storage is not configured" do
      # No minio cluster exists for the timeline's location, so blob_storage is nil
      resource = create_postgres_resource(project:, location_id:)
      create_postgres_server(resource:, timeline: postgres_timeline, strand_label: "wait")

      expect(nx.postgres_timeline.blob_storage).to be_nil
      expect { nx.wait }.to nap(20 * 60)
    end

    it "self-destructs if there's no leader, no backups and the timeline is old enough" do
      create_minio_cluster
      resource = create_postgres_resource(project:, location_id:)
      server = create_postgres_server(resource:, timeline: postgres_timeline, strand_label: "wait")
      server.destroy
      postgres_timeline.update(created_at: Time.now - 11 * 24 * 60 * 60)

      mock_minio_client(list_objects: [])

      expect(Clog).to receive(:emit).with(/Self-destructing timeline/, postgres_timeline)
      expect { nx.wait }.to hop("destroy")
    end

    it "hops to take_backup if backup is needed" do
      create_minio_cluster
      resource = create_postgres_resource(project:, location_id:)
      create_postgres_server(resource:, timeline: postgres_timeline, strand_label: "wait")

      backup = backup_fixture(days_ago: 3)
      mock_minio_client(list_objects: [backup])

      expect(nx.postgres_timeline.leader.vm.sshable).to receive(:_cmd).with("common/bin/daemonizer --check take_postgres_backup").and_return("NotStarted")

      expect { nx.wait }.to hop("take_backup")
    end

    it "creates a missing backup page if last completed backup is older than 2 days" do
      create_minio_cluster
      resource = create_postgres_resource(project:, location_id:)
      create_postgres_server(resource:, timeline: postgres_timeline, strand_label: "wait")
      # Set latest_backup_started_at to avoid need_backup? returning true due to nil check
      postgres_timeline.update(latest_backup_started_at: Time.now)

      backup = backup_fixture(days_ago: 3)
      mock_minio_client(list_objects: [backup])

      expect(nx.postgres_timeline.leader.vm.sshable).to receive(:_cmd).with("common/bin/daemonizer --check take_postgres_backup").and_return("Succeeded")

      expect { nx.wait }.to nap(20 * 60)
      expect(Page.active.count).to eq(1)
    end

    it "resolves the missing page if last completed backup is more recent than 2 days" do
      create_minio_cluster
      resource = create_postgres_resource(project:, location_id:)
      create_postgres_server(resource:, timeline: postgres_timeline, strand_label: "wait")
      # Set latest_backup_started_at to avoid need_backup? returning true due to nil check
      postgres_timeline.update(latest_backup_started_at: Time.now)

      backup = backup_fixture(days_ago: 1)
      mock_minio_client(list_objects: [backup])

      expect(nx.postgres_timeline.leader.vm.sshable).to receive(:_cmd).with("common/bin/daemonizer --check take_postgres_backup").and_return("Succeeded")

      # Create a real Page with the "MissingBackup" tag and its Strand (needed for semaphores)
      page = Page.create(tag: Page.generate_tag(["MissingBackup", postgres_timeline.id]), summary: "Missing backup")
      Strand.create_with_id(page, prog: "PageNexus", label: "wait")

      expect { nx.wait }.to nap(20 * 60)
      expect(Semaphore.where(strand_id: page.id, name: "resolve").count).to eq(1)
    end

    it "naps if there is nothing to do" do
      create_minio_cluster
      resource = create_postgres_resource(project:, location_id:)
      create_postgres_server(resource:, timeline: postgres_timeline, strand_label: "wait")
      # Set latest_backup_started_at to avoid need_backup? returning true due to nil check
      postgres_timeline.update(latest_backup_started_at: Time.now)

      backup = backup_fixture(days_ago: 1)
      mock_minio_client(list_objects: [backup])

      expect(nx.postgres_timeline.leader.vm.sshable).to receive(:_cmd).with("common/bin/daemonizer --check take_postgres_backup").and_return("Succeeded")

      expect { nx.wait }.to nap(20 * 60)
    end
  end

  describe "#take_backup" do
    let(:minio_cluster) { create_minio_cluster }
    let(:resource) { create_postgres_resource(project:, location_id:) }
    let(:server) { create_postgres_server(resource:, timeline: postgres_timeline, strand_label: "wait") }

    before do
      minio_cluster
      server
    end

    it "hops to wait if backup is not needed" do
      # Set latest_backup_started_at to recent so "Succeeded" makes need_backup? return false
      postgres_timeline.update(latest_backup_started_at: Time.now)

      # need_backup? calls sshable.cmd once, returns "Succeeded" so need_backup? is false
      expect(nx.postgres_timeline.leader.vm.sshable).to receive(:_cmd).with("common/bin/daemonizer --check take_postgres_backup").and_return("Succeeded")

      expect { nx.take_backup }.to hop("wait")
    end

    it "takes backup if it is needed" do
      # need_backup? is called once (returns true because NotStarted),
      # then cmd is called to run the backup
      sshable = nx.postgres_timeline.leader.vm.sshable
      expect(sshable).to receive(:_cmd).with("common/bin/daemonizer --check take_postgres_backup").and_return("NotStarted").ordered
      expect(sshable).to receive(:_cmd).with("common/bin/daemonizer sudo\\ postgres/bin/take-backup\\ 16 take_postgres_backup").ordered

      expect { nx.take_backup }.to hop("wait")
      expect(postgres_timeline.reload.latest_backup_started_at).not_to be_nil
    end
  end

  describe "#destroy" do
    it "completes destroy even if dns zone and blob_storage are not configured" do
      # No minio cluster, so blob_storage is nil
      expect { nx.destroy }.to exit({"msg" => "postgres timeline is deleted"})
      expect(postgres_timeline).not_to exist
    end

    describe "when blob storage is minio" do
      it "destroys blob storage and postgres timeline" do
        minio_cluster = create_minio_cluster
        admin_client = mock_admin_minio_client(minio_cluster)

        expect(admin_client).to receive(:admin_remove_user).with(postgres_timeline.access_key).and_return(200)
        expect(admin_client).to receive(:admin_policy_remove).with(postgres_timeline.ubid).and_return(200)

        expect { nx.destroy }.to exit({"msg" => "postgres timeline is deleted"})
        expect(postgres_timeline).not_to exist
      end
    end

    describe "when blob storage is aws s3" do
      let(:aws_location) { create_aws_location }
      let(:iam_client) { Aws::IAM::Client.new(stub_responses: true) }

      before do
        postgres_timeline.update(location_id: aws_location.id)
      end

      it "destroys blob storage and postgres timeline" do
        iam_client.stub_responses(:delete_user)
        iam_client.stub_responses(:list_attached_user_policies, attached_policies: [{policy_arn: "arn:aws:iam::aws:policy/AmazonS3FullAccess"}])
        iam_client.stub_responses(:delete_policy)
        iam_client.stub_responses(:list_access_keys, access_key_metadata: [{access_key_id: "access-key"}])
        iam_client.stub_responses(:delete_access_key)
        expect(nx.postgres_timeline.location.location_credential).to receive(:iam_client).and_return(iam_client).at_least(:once)

        expect { nx.destroy }.to exit({"msg" => "postgres timeline is deleted"})
        expect(postgres_timeline).not_to exist
      end
    end
  end
end
