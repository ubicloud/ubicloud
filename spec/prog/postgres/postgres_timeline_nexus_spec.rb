# frozen_string_literal: true

require_relative "../../model/spec_helper"

RSpec.describe Prog::Postgres::PostgresTimelineNexus do
  subject(:nx) { described_class.new(Strand.new(id: "8148ebdf-66b8-8ed0-9c2f-8cfe93f5aa77")) }

  let(:postgres_timeline) {
    instance_double(
      PostgresTimeline,
      ubid: "ptp99pd7gwyp4jcvnzgrsd443g",
      blob_storage_endpoint: "https://blob-endpoint",
      blob_storage_client: instance_double(MinioClient)
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
      expect(postgres_timeline.blob_storage_client).to receive(:create_bucket).with(bucket_name: postgres_timeline.ubid)
      expect { nx.start }.to hop("wait_leader")
    end

    it "hops without creating bucket if blob storage is not configures" do
      expect(postgres_timeline).to receive(:blob_storage_endpoint).and_return(nil)
      expect(postgres_timeline.blob_storage_client).not_to receive(:create_bucket)
      expect { nx.start }.to hop("wait_leader")
    end
  end

  describe "#wait_leader" do
    it "naps if leader not ready" do
      expect(postgres_timeline).to receive(:leader).and_return(instance_double(PostgresServer, strand: instance_double(Strand, label: "start")))
      expect { nx.wait_leader }.to nap(5)
    end

    it "hops if leader is ready" do
      expect(postgres_timeline).to receive(:leader).and_return(instance_double(PostgresServer, strand: instance_double(Strand, label: "wait")))
      expect { nx.wait_leader }.to hop("wait")
    end
  end

  describe "#wait" do
    it "hops to take_backup if backup is needed" do
      expect(postgres_timeline).to receive(:need_backup?).and_return(true)
      expect { nx.wait }.to hop("take_backup")
    end

    it "naps if there is nothing to do" do
      expect(postgres_timeline).to receive(:need_backup?).and_return(false)
      expect { nx.wait }.to nap(30)
    end
  end

  describe "#take_backup" do
    it "updates last_backup_started_at even if backup is not needed" do
      expect(postgres_timeline).to receive(:need_backup?).and_return(false)
      expect(postgres_timeline).to receive(:last_backup_started_at=)
      expect(postgres_timeline).to receive(:save_changes)
      expect { nx.take_backup }.to hop("wait")
    end

    it "takes backup if it is needed" do
      expect(postgres_timeline).to receive(:need_backup?).and_return(true)
      sshable = instance_double(Sshable)
      expect(sshable).to receive(:cmd).with("common/bin/daemonizer 'sudo postgres/bin/take-backup' take_postgres_backup")
      expect(postgres_timeline).to receive(:leader).and_return(instance_double(PostgresServer, vm: instance_double(Vm, sshable: sshable)))
      expect(postgres_timeline).to receive(:last_backup_started_at=)
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
