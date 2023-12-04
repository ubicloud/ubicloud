# frozen_string_literal: true

require_relative "../../model/spec_helper"

RSpec.describe Prog::Postgres::PostgresTimelineNexus do
  subject(:nx) { described_class.new(Strand.new(id: "8148ebdf-66b8-8ed0-9c2f-8cfe93f5aa77")) }

  let(:postgres_timeline) {
    instance_double(
      PostgresTimeline,
      id: "b253669e-1cf5-8ada-9337-5fc319690838",
      ubid: "ptp99pd7gwyp4jcvnzgrsd443g",
      blob_storage: "dummy-blob-storage",
      blob_storage_client: instance_double(Minio::Client)
    )
  }

  before do
    allow(nx).to receive(:postgres_timeline).and_return(postgres_timeline)
  end

  describe ".assemble" do
    it "creates postgres timeline" do
      st = described_class.assemble

      postgres_timeline = PostgresTimeline[st.id]
      expect(postgres_timeline).not_to be_nil
    end
  end

  describe "#before_run" do
    it "hops to destroy when needed" do
      expect(nx).to receive(:when_destroy_set?).and_yield
      expect { nx.before_run }.to hop("destroy")
    end

    it "does not hop to destroy if already in the destroy state" do
      expect(nx).to receive(:when_destroy_set?).and_yield
      expect(nx.strand).to receive(:label).and_return("destroy")
      expect { nx.before_run }.not_to hop("destroy")
    end
  end

  describe "#start" do
    it "creates bucket and hops" do
      expect(postgres_timeline.blob_storage_client).to receive(:create_bucket).with(postgres_timeline.ubid)
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
      expect { nx.wait }.to hop("take_backup")
    end

    it "creates a missing backup page if last completed backup is older than 2 days" do
      expect(postgres_timeline).to receive(:need_backup?).and_return(false)
      stub_const("Backup", Struct.new(:last_modified))
      expect(postgres_timeline).to receive(:backups).and_return([instance_double(Backup, last_modified: Time.now - 3 * 24 * 60 * 60)])
      expect(postgres_timeline).to receive(:leader).and_return(instance_double(PostgresServer))
      expect { nx.wait }.to nap(20 * 60)
      expect(Page.active.count).to eq(1)
    end

    it "resolves the missing page if last completed backup is more recent than 2 days" do
      expect(postgres_timeline).to receive(:need_backup?).and_return(false)
      stub_const("Backup", Struct.new(:last_modified))
      expect(postgres_timeline).to receive(:backups).and_return([instance_double(Backup, last_modified: Time.now - 1 * 24 * 60 * 60)])
      expect(postgres_timeline).to receive(:leader).and_return(instance_double(PostgresServer))
      page = instance_double(Page)
      expect(page).to receive(:incr_resolve)
      expect(Page).to receive(:from_tag_parts).and_return(page)

      expect { nx.wait }.to nap(20 * 60)
    end

    it "naps if there is nothing to do" do
      expect(postgres_timeline).to receive(:need_backup?).and_return(false)
      stub_const("Backup", Struct.new(:last_modified))
      expect(postgres_timeline).to receive(:backups).and_return([instance_double(Backup, last_modified: Time.now - 1 * 24 * 60 * 60)])
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
      expect(sshable).to receive(:cmd).with("common/bin/daemonizer 'sudo postgres/bin/take-backup' take_postgres_backup")
      expect(postgres_timeline).to receive(:leader).and_return(instance_double(PostgresServer, vm: instance_double(Vm, sshable: sshable)))
      expect(postgres_timeline).to receive(:latest_backup_started_at=)
      expect(postgres_timeline).to receive(:save_changes)
      expect { nx.take_backup }.to hop("wait")
    end
  end

  describe "#destroy" do
    it "completes destroy even if dns zone is not configured" do
      expect(postgres_timeline).to receive(:destroy)
      expect { nx.destroy }.to exit({"msg" => "postgres timeline is deleted"})
    end
  end
end
