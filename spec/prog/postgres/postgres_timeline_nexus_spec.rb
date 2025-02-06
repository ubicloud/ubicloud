# frozen_string_literal: true

require_relative "../../model/spec_helper"

RSpec.describe Prog::Postgres::PostgresTimelineNexus do
  subject(:nx) { described_class.new(Strand.new(id: "8148ebdf-66b8-8ed0-9c2f-8cfe93f5aa77")) }

  let(:postgres_timeline) {
    instance_double(
      PostgresTimeline,
      id: "b253669e-1cf5-8ada-9337-5fc319690838",
      ubid: "ptp99pd7gwyp4jcvnzgrsd443g",
      blob_storage: instance_double(MinioCluster, url: "https://blob-endpoint", root_certs: "certs"),
      blob_storage_endpoint: "https://blob-endpoint",
      blob_storage_client: instance_double(Minio::Client),
      access_key: "dummy-access-key",
      secret_key: "dummy-secret-key",
      blob_storage_policy: {"Version" => "2012-10-17", "Statement" => [{"Action" => ["s3:GetBucketLocation"], "Effect" => "Allow", "Principal" => {"AWS" => ["*"]}, "Resource" => ["arn:aws:s3:::test"], "Sid" => ""}]}
    )
  }

  before do
    allow(nx).to receive(:postgres_timeline).and_return(postgres_timeline)
  end

  describe ".assemble" do
    it "throws an exception if parent is not found" do
      expect {
        described_class.assemble(parent_id: "69c0f4cd-99c1-8ed0-acfe-7b013ce2fa0b")
      }.to raise_error RuntimeError, "No existing parent"
    end

    it "creates postgres timeline" do
      st = described_class.assemble

      postgres_timeline = PostgresTimeline[st.id]
      expect(postgres_timeline).not_to be_nil
    end

    it "creates postgres timeline with blob storage when it exists" do
      project = Project.create_with_id(name: "mc-project")
      expect(Config).to receive(:minio_service_project_id).and_return(project.id).at_least(:once)
      expect(Config).to receive(:postgres_service_project_id).and_return(project.id)
      mc = Prog::Minio::MinioClusterNexus.assemble(project.id, "minio", "hetzner-fsn1", "minio-admin", 100, 1, 1, 1, "standard-2").subject

      st = described_class.assemble(location: "hetzner-fsn1")

      postgres_timeline = PostgresTimeline[st.id]
      expect(postgres_timeline.blob_storage_id).to eq(mc.id)
    end
  end

  describe "#start" do
    let(:admin_blob_storage_client) { instance_double(Minio::Client) }
    let(:blob_storage_client) { instance_double(Minio::Client) }

    it "creates bucket and hops" do
      expect(postgres_timeline).to receive(:blob_storage).and_return(instance_double(MinioCluster, url: "https://blob-endpoint", root_certs: "certs", admin_user: "admin", admin_password: "secret")).at_least(:once)
      expect(Minio::Client).to receive(:new).with(endpoint: "https://blob-endpoint", access_key: "admin", secret_key: "secret", ssl_ca_file_data: "certs").and_return(admin_blob_storage_client)
      expect(postgres_timeline).to receive(:blob_storage_client).and_return(blob_storage_client).twice
      expect(admin_blob_storage_client).to receive(:admin_add_user).with(postgres_timeline.access_key, postgres_timeline.secret_key).and_return(200)
      expect(admin_blob_storage_client).to receive(:admin_policy_add).with(postgres_timeline.ubid, postgres_timeline.blob_storage_policy).and_return(200)
      expect(admin_blob_storage_client).to receive(:admin_policy_set).with(postgres_timeline.ubid, postgres_timeline.access_key).and_return(200)
      expect(blob_storage_client).to receive(:create_bucket).with(postgres_timeline.ubid).and_return(200)
      expect(blob_storage_client).to receive(:set_lifecycle_policy).with(postgres_timeline.ubid, postgres_timeline.ubid, 8).and_return(200)
      expect { nx.start }.to hop("wait_leader")
    end

    it "hops without creating bucket if blob storage is not configures" do
      expect(postgres_timeline).to receive(:blob_storage).and_return(nil)
      expect(postgres_timeline.blob_storage_client).not_to receive(:create_bucket)
      expect { nx.start }.to hop("wait_leader")
    end
  end

  describe "#wait_leader" do
    it "hops to destroy if leader is missing" do
      expect(postgres_timeline).to receive(:leader).and_return(nil)
      expect { nx.wait_leader }.to hop("destroy")
    end

    it "naps if leader not ready" do
      expect(postgres_timeline).to receive(:leader).and_return(instance_double(PostgresServer, strand: instance_double(Strand, label: "start"))).twice
      expect { nx.wait_leader }.to nap(5)
    end

    it "hops if leader is ready" do
      expect(postgres_timeline).to receive(:leader).and_return(instance_double(PostgresServer, strand: instance_double(Strand, label: "wait"))).twice
      expect { nx.wait_leader }.to hop("wait")
    end
  end

  describe "#wait" do
    it "naps if blob storage is not configures" do
      expect(postgres_timeline).to receive(:blob_storage).and_return(nil)
      expect { nx.wait }.to nap(20 * 60)
    end

    it "hops to take_backup if backup is needed" do
      expect(postgres_timeline).to receive(:need_backup?).and_return(true)
      backup = Struct.new(:last_modified)
      expect(postgres_timeline).to receive(:backups).and_return([instance_double(backup, last_modified: Time.now - 3 * 24 * 60 * 60)])
      expect(postgres_timeline).to receive(:leader).and_return(instance_double(PostgresServer))
      expect { nx.wait }.to hop("take_backup")
    end

    it "creates a missing backup page if last completed backup is older than 2 days" do
      expect(postgres_timeline).to receive(:need_backup?).and_return(false)
      backup = Struct.new(:last_modified)
      expect(postgres_timeline).to receive(:backups).and_return([instance_double(backup, last_modified: Time.now - 3 * 24 * 60 * 60)])
      expect(postgres_timeline).to receive(:leader).and_return(instance_double(PostgresServer))
      expect { nx.wait }.to nap(20 * 60)
      expect(Page.active.count).to eq(1)
    end

    it "resolves the missing page if last completed backup is more recent than 2 days" do
      expect(postgres_timeline).to receive(:need_backup?).and_return(false)
      backup = Struct.new(:last_modified)
      expect(postgres_timeline).to receive(:backups).and_return([instance_double(backup, last_modified: Time.now - 1 * 24 * 60 * 60)])
      expect(postgres_timeline).to receive(:leader).and_return(instance_double(PostgresServer))
      page = instance_double(Page)
      expect(page).to receive(:incr_resolve)
      expect(Page).to receive(:from_tag_parts).and_return(page)

      expect { nx.wait }.to nap(20 * 60)
    end

    it "naps if there is nothing to do" do
      expect(postgres_timeline).to receive(:need_backup?).and_return(false)
      backup = Struct.new(:last_modified)
      expect(postgres_timeline).to receive(:backups).and_return([instance_double(backup, last_modified: Time.now - 1 * 24 * 60 * 60)])
      expect(postgres_timeline).to receive(:leader).and_return(instance_double(PostgresServer))

      expect { nx.wait }.to nap(20 * 60)
    end
  end

  describe "#take_backup" do
    it "hops to wait if backup is not needed" do
      expect(postgres_timeline).to receive(:need_backup?).and_return(false)
      expect { nx.take_backup }.to hop("wait")
    end

    it "takes backup if it is needed" do
      expect(postgres_timeline).to receive(:need_backup?).and_return(true)
      sshable = instance_double(Sshable)
      expect(sshable).to receive(:cmd).with("common/bin/daemonizer 'sudo postgres/bin/take-backup 16' take_postgres_backup")
      expect(postgres_timeline).to receive(:leader).and_return(instance_double(PostgresServer, resource: instance_double(PostgresResource, version: "16"), vm: instance_double(Vm, sshable: sshable))).at_least(:once)
      expect(postgres_timeline).to receive(:latest_backup_started_at=)
      expect(postgres_timeline).to receive(:save_changes)
      expect { nx.take_backup }.to hop("wait")
    end
  end

  describe "#destroy" do
    let(:admin_blob_storage_client) { instance_double(Minio::Client) }

    it "completes destroy even if dns zone and blob_storage are not configured" do
      expect(postgres_timeline).to receive(:blob_storage).and_return(nil)
      expect(postgres_timeline).to receive(:destroy)
      expect { nx.destroy }.to exit({"msg" => "postgres timeline is deleted"})
    end

    it "destroys blob storage and postgres timeline" do
      expect(postgres_timeline).to receive(:blob_storage).and_return(instance_double(MinioCluster, url: "https://blob-endpoint", root_certs: "certs", admin_user: "admin", admin_password: "secret")).at_least(:once)
      expect(postgres_timeline).to receive(:destroy)

      expect(Minio::Client).to receive(:new).with(endpoint: postgres_timeline.blob_storage_endpoint, access_key: "admin", secret_key: "secret", ssl_ca_file_data: "certs").and_return(admin_blob_storage_client)
      expect(admin_blob_storage_client).to receive(:admin_remove_user).with(postgres_timeline.access_key).and_return(200)
      expect(admin_blob_storage_client).to receive(:admin_policy_remove).with(postgres_timeline.ubid).and_return(200)
      expect { nx.destroy }.to exit({"msg" => "postgres timeline is deleted"})
    end
  end
end
