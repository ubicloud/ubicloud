# frozen_string_literal: true

require_relative "../../model/spec_helper"

RSpec.describe Prog::Postgres::PostgresTimelineNexus do
  subject(:nx) { described_class.new(Strand.new(id: "8148ebdf-66b8-8ed0-9c2f-8cfe93f5aa77")) }

  let(:postgres_timeline) {
    instance_double(
      PostgresTimeline,
      ubid: "ptp99pd7gwyp4jcvnzgrsd443g",
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
      expect { nx.start }.to hop("wait")
    end
  end

  describe "#wait" do
    it "naps" do
      expect { nx.wait }.to nap(30)
    end
  end

  describe "#destroy" do
    it "completes destroy even if dns zone is not configured" do
      expect(postgres_timeline).to receive(:destroy)
      expect { nx.destroy }.to exit({"msg" => "postgres timeline is deleted"})
    end
  end
end
